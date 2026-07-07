# Ejercicios guiados — Tema 3.3: Turning Commands into a Script

**Certificación:** LPI Linux Essentials (010-160, versión 1.6) · **Peso:** 4
**Referencia:** [LPI Learning Materials 3.3](https://learning.lpi.org/en/learning-materials/010-160/3/3.3/)

Trabajá en una terminal con Bash. Todos los ejercicios se hacen dentro de un directorio de práctica que creamos en el primer paso.

---

## Ejercicio 1: Tu primer script — shebang y permisos

1. Creá un directorio de trabajo y entrá en él:
   ```bash
   mkdir ~/practica-scripts
   cd ~/practica-scripts
   ```
2. Creá un archivo llamado `hola.sh` con un editor de texto (por ejemplo `nano hola.sh`) y escribí este contenido:
   ```bash
   #!/bin/bash
   # Mi primer script
   echo "Hola desde mi script"
   ```
3. Guardá el archivo e intentá ejecutarlo directamente:
   ```bash
   ./hola.sh
   ```
   Observá el mensaje de error: `Permission denied`.
4. Verificá los permisos actuales del archivo:
   ```bash
   ls -l hola.sh
   ```
5. Agregá el permiso de ejecución y volvé a intentar:
   ```bash
   chmod +x hola.sh
   ./hola.sh
   ```
6. Ejecutalo también de esta otra forma, que funciona aun sin permiso de ejecución:
   ```bash
   bash hola.sh
   ```

**Preguntas:**

**1.a)** ¿Qué función cumple la primera línea `#!/bin/bash` (el *shebang*)? ¿Qué pasaría si el script no la tuviera?

**1.b)** ¿Por qué `bash hola.sh` funciona sin permiso de ejecución, pero `./hola.sh` no?

**1.c)** ¿Por qué hay que escribir `./hola.sh` en lugar de simplemente `hola.sh`?

---

## Ejercicio 2: Comentarios y `echo`

1. Creá un script llamado `info.sh` con este contenido y dale permiso de ejecución:
   ```bash
   #!/bin/bash
   # Este script muestra información básica
   echo "Usuario actual:"
   whoami   # muestra el nombre del usuario
   echo     # línea en blanco
   echo -n "Directorio actual: "
   pwd
   ```
2. Ejecutalo:
   ```bash
   chmod +x info.sh
   ./info.sh
   ```
3. Observá la diferencia entre las líneas con `echo` normal y la que usa `echo -n`.

**Preguntas:**

**2.a)** En la línea `whoami   # muestra el nombre del usuario`, ¿el shell intenta ejecutar el texto después del `#`? ¿Por qué?

**2.b)** ¿Qué hace la opción `-n` de `echo`?

**2.c)** El shebang también empieza con `#`. ¿Es un comentario común? ¿En qué se diferencia?

---

## Ejercicio 3: Variables

1. Creá un script llamado `variables.sh`:
   ```bash
   #!/bin/bash
   NOMBRE="Ana"
   DISTRO="Debian"
   echo "Hola, $NOMBRE"
   echo "Tu distribución es $DISTRO"
   ARCHIVOS=$(ls | wc -l)
   echo "Hay $ARCHIVOS archivos en este directorio"
   ```
2. Dale permiso de ejecución y ejecutalo:
   ```bash
   chmod +x variables.sh
   ./variables.sh
   ```
3. Ahora editá el script y probá introducir un espacio en la asignación, así: `NOMBRE = "Ana"`. Ejecutalo de nuevo y observá el error.
4. Corregí la línea (sin espacios) antes de seguir.

**Preguntas:**

**3.a)** ¿Por qué falla la asignación `NOMBRE = "Ana"` con espacios alrededor del `=`?

**3.b)** ¿Qué hace la construcción `$(ls | wc -l)`? ¿Cómo se llama este mecanismo?

**3.c)** ¿Qué símbolo se usa para *leer* el valor de una variable, y qué se escribe para *asignarla*?

---

## Ejercicio 4: Argumentos del script

1. Creá un script llamado `saludo.sh`:
   ```bash
   #!/bin/bash
   echo "Script ejecutado: $0"
   echo "Primer argumento: $1"
   echo "Segundo argumento: $2"
   echo "Cantidad de argumentos: $#"
   echo "Todos los argumentos: $@"
   ```
2. Dale permiso de ejecución y probalo con distintos argumentos:
   ```bash
   chmod +x saludo.sh
   ./saludo.sh hola mundo
   ./saludo.sh uno dos tres cuatro
   ./saludo.sh
   ```
3. Observá qué muestra cada variable especial en cada caso.

**Preguntas:**

**4.a)** ¿Qué contiene `$0`? ¿Cuenta como argumento en `$#`?

**4.b)** Si ejecutás `./saludo.sh uno dos tres cuatro`, ¿qué valor muestra `$#` y qué muestra `$@`?

**4.c)** ¿Qué muestra `$1` cuando el script se ejecuta sin argumentos?

---

## Ejercicio 5: Exit codes y ejecución condicional

1. Ejecutá un comando que funciona y consultá su código de salida:
   ```bash
   ls ~
   echo $?
   ```
2. Ahora ejecutá un comando que falla y consultá el código de nuevo:
   ```bash
   ls /directorio-inexistente
   echo $?
   ```
3. Creá un script llamado `chequeo.sh` que use el exit code en una condición:
   ```bash
   #!/bin/bash
   if grep -q "$1" /etc/passwd
   then
       echo "El usuario $1 existe en el sistema"
       exit 0
   else
       echo "El usuario $1 NO existe"
       exit 1
   fi
   ```
4. Probalo con tu usuario y con uno inventado, verificando el exit code cada vez:
   ```bash
   chmod +x chequeo.sh
   ./chequeo.sh $USER
   echo $?
   ./chequeo.sh usuario-falso
   echo $?
   ```

**Preguntas:**

**5.a)** Por convención, ¿qué significa un exit code `0` y qué significa uno distinto de `0`?

**5.b)** ¿Qué contiene la variable especial `$?`?

**5.c)** En el script `chequeo.sh`, ¿qué evalúa el `if` para decidir qué rama ejecutar?

**5.d)** Si después de `./chequeo.sh usuario-falso` ejecutás `echo $?` dos veces seguidas, ¿qué muestra la segunda vez? ¿Por qué?

---

## Ejercicio 6: Bucles con `for`

1. Creá un script llamado `bucle.sh`:
   ```bash
   #!/bin/bash
   for ARCHIVO in $(ls *.sh)
   do
       echo "Encontré el script: $ARCHIVO"
   done

   for NUMERO in 1 2 3
   do
       echo "Iteración número $NUMERO"
   done
   ```
2. Dale permiso de ejecución y ejecutalo:
   ```bash
   chmod +x bucle.sh
   ./bucle.sh
   ```
3. Modificá el primer bucle para que además muestre el tamaño de cada archivo, agregando dentro del `do ... done`:
   ```bash
   du -h "$ARCHIVO"
   ```
4. Ejecutalo de nuevo y verificá el resultado.

**Preguntas:**

**6.a)** ¿Qué tres palabras clave delimitan la estructura de un bucle `for` en Bash?

**6.b)** En cada vuelta del primer bucle, ¿qué valor toma la variable `ARCHIVO`?

**6.c)** ¿Cuántas líneas imprime el segundo bucle y por qué?

---

## Ejercicio 7: Un script útil y su ubicación en el `PATH`

1. Creá un script llamado `resumen.sh` que combine lo aprendido:
   ```bash
   #!/bin/bash
   # resumen.sh - muestra un resumen de un directorio
   # Uso: resumen.sh <directorio>

   if [ $# -eq 0 ]
   then
       echo "Uso: $0 <directorio>"
       exit 1
   fi

   DIR=$1
   echo "Resumen de $DIR:"
   CANTIDAD=$(ls "$DIR" | wc -l)
   echo "Contiene $CANTIDAD elementos"
   for ELEMENTO in $(ls "$DIR")
   do
       echo " - $ELEMENTO"
   done
   exit 0
   ```
2. Probalo:
   ```bash
   chmod +x resumen.sh
   ./resumen.sh
   ./resumen.sh ~/practica-scripts
   ```
3. Consultá qué directorios recorre el shell para encontrar comandos:
   ```bash
   echo $PATH
   ```
4. Copiá el script a un directorio del `PATH` para poder ejecutarlo desde cualquier lugar (requiere privilegios de administrador):
   ```bash
   sudo cp resumen.sh /usr/local/bin/resumen
   ```
5. Verificá que ahora funciona como cualquier otro comando, sin `./` y desde cualquier directorio:
   ```bash
   cd ~
   resumen ~/practica-scripts
   which resumen
   ```

**Preguntas:**

**7.a)** ¿Qué verifica la condición `[ $# -eq 0 ]` y por qué es una buena práctica incluirla?

**7.b)** ¿Qué es la variable `PATH` y qué relación tiene con poder ejecutar `resumen` sin escribir `./`?

**7.c)** ¿Por qué `/usr/local/bin` es un lugar apropiado para scripts propios, en lugar de `/usr/bin`?

**7.d)** ¿Qué comando te permite averiguar desde qué ubicación se está ejecutando `resumen`?

---

<details>
<summary><strong>Respuestas</strong></summary>

### Ejercicio 1

**1.a)** El *shebang* (`#!`) indica al sistema qué intérprete debe usar para ejecutar el script; en este caso `/bin/bash`. Debe ser la primera línea del archivo. Si no existiera, el script se ejecutaría con el shell actual del usuario, lo que puede dar resultados distintos a los esperados si ese shell no es Bash (por ejemplo, si el usuario usa `zsh` o `dash`).

**1.b)** Con `bash hola.sh` el programa que se ejecuta es `bash`, y el script es solo un archivo de datos que Bash *lee*; para eso alcanza con permiso de lectura. Con `./hola.sh` le pedís al kernel que ejecute el archivo directamente, y para eso el archivo necesita el permiso de ejecución (`x`), que se agrega con `chmod +x`.

**1.c)** Porque el directorio actual normalmente **no** está en la variable `PATH` por razones de seguridad. Al escribir `./hola.sh` indicás la ruta explícita al archivo (`.` es el directorio actual), así el shell no necesita buscarlo en el `PATH`.

### Ejercicio 2

**2.a)** No. Todo lo que sigue a `#` en una línea es un comentario: el shell lo ignora por completo. Los comentarios sirven para documentar el script y pueden ir en su propia línea o al final de una línea de código.

**2.b)** `echo -n` imprime el texto **sin** el salto de línea final. Por eso la salida de `pwd` aparece a continuación, en la misma línea que "Directorio actual: ".

**2.c)** Sintácticamente el shebang es un comentario (empieza con `#`), y por eso Bash lo ignora al interpretar el script. Pero cuando el kernel ejecuta el archivo, la secuencia especial `#!` en la primera línea le indica qué intérprete lanzar. Es decir: es un comentario para el shell, pero tiene significado especial para el sistema, y solo en la primera línea.

### Ejercicio 3

**3.a)** Porque con espacios, Bash interpreta `NOMBRE` como un **comando** con dos argumentos (`=` y `"Ana"`), no como una asignación. Al no existir un comando llamado `NOMBRE`, da error `command not found`. En Bash las asignaciones se escriben sin espacios: `NOMBRE="Ana"`.

**3.b)** Es *command substitution* (sustitución de comandos): Bash ejecuta el comando entre `$( )` (aquí `ls | wc -l`, que cuenta los archivos del directorio) y reemplaza la expresión por su salida, que queda guardada en la variable `ARCHIVOS`. La sintaxis antigua con backticks (`` ` ` ``) hace lo mismo.

**3.c)** Para leer el valor se antepone `$` (por ejemplo `$NOMBRE`); para asignar se usa solo el nombre, sin `$` y sin espacios: `NOMBRE=valor`.

### Ejercicio 4

**4.a)** `$0` contiene el nombre con el que se invocó el script (por ejemplo `./saludo.sh`). No cuenta como argumento: `$#` cuenta solo los argumentos posicionales `$1`, `$2`, etc.

**4.b)** `$#` muestra `4` (la cantidad de argumentos) y `$@` muestra todos los argumentos: `uno dos tres cuatro`.

**4.c)** Nada: `$1` está vacío, así que la línea imprime `Primer argumento:` sin valor a continuación. No produce error.

### Ejercicio 5

**5.a)** `0` significa que el comando terminó **con éxito**; cualquier valor distinto de `0` (de 1 a 255) indica algún tipo de **error o fallo**. Los scripts pueden fijar su propio código con el comando `exit`.

**5.b)** `$?` contiene el exit code del **último comando ejecutado**.

**5.c)** El `if` evalúa el exit code del comando `grep -q "$1" /etc/passwd`: si es `0` (grep encontró el patrón) ejecuta la rama `then`; si es distinto de `0` (no lo encontró) ejecuta la rama `else`.

**5.d)** La segunda vez muestra `0`. Como `$?` refleja el último comando ejecutado, el primer `echo $?` mostró el `1` del script, pero ese `echo` a su vez terminó con éxito, así que el segundo `echo $?` muestra el exit code del primer `echo`, que es `0`.

### Ejercicio 6

**6.a)** `for`, `do` y `done`. La lista de valores se indica después de `in`, y los comandos a repetir van entre `do` y `done`.

**6.b)** En cada iteración, `ARCHIVO` toma el nombre de uno de los archivos `.sh` que devolvió `ls *.sh` (por ejemplo `hola.sh`, luego `info.sh`, etc.), uno por vuelta.

**6.c)** Tres líneas, porque la lista después de `in` tiene tres elementos (`1 2 3`) y el cuerpo del bucle se ejecuta una vez por cada elemento.

### Ejercicio 7

**7.a)** Verifica si la cantidad de argumentos (`$#`) es igual (`-eq`) a cero, es decir, si el usuario no pasó ningún argumento. Es una buena práctica porque permite mostrar un mensaje de uso y terminar con `exit 1` (error) en lugar de que el script falle más adelante de forma confusa al operar sobre un directorio vacío o inexistente.

**7.b)** `PATH` es una variable de entorno con la lista de directorios (separados por `:`) donde el shell busca los ejecutables cuando escribís un comando sin ruta. Al copiar el script a `/usr/local/bin`, que está en el `PATH`, el shell lo encuentra por su nombre y ya no hace falta el prefijo `./` ni estar en el directorio del script.

**7.c)** `/usr/local/bin` está reservado para programas instalados localmente por el administrador, mientras que `/usr/bin` lo gestiona el package manager de la distribución. Poner scripts propios en `/usr/local/bin` evita conflictos con actualizaciones de paquetes y mantiene separado lo local de lo que provee el sistema.

**7.d)** `which resumen`, que muestra la ruta del ejecutable que el shell encontraría en el `PATH` (en este caso `/usr/local/bin/resumen`). El comando `type resumen` da información similar.

</details>

---

**Fuente de referencia:** [LPI Learning Materials — Tema 3.3, Turning Commands into a Script](https://learning.lpi.org/en/learning-materials/010-160/3/3.3/)