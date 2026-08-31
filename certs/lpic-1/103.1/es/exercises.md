# 103.1 — Trabajar en la línea de comandos
## Ejercicios guiados (LPIC-1, examen 101-500 v5.0)

**Alcance cubierto:** comandos simples y secuencias de comandos en una sola línea · variables de shell vs. variables de entorno (`set`, `unset`, `export`, `env`) · resolución de comandos y `PATH` · quoting · historial de comandos y `.bash_history` · `man` y autodocumentación · `uname`, `pwd`, `echo`, `type`, `which`.

**Fuentes de referencia**
- Objetivos del examen LPI 101-500 — <https://www.lpi.org/our-certifications/exam-101-objectives/>
- GNU Bash Reference Manual — <https://www.gnu.org/software/bash/manual/bash.html>
- GNU Coreutils Manual — <https://www.gnu.org/software/coreutils/manual/coreutils.html>
- Proyecto `man-pages` de Linux — <https://www.kernel.org/doc/man-pages/>

---

## Antes de empezar

Estos ejercicios asumen una shell **Bash 5.x** interactiva sobre cualquier distribución mayoritaria, ejecutándose como **usuario sin privilegios**. No hace falta `sudo`. La salida exacta byte a byte varía según la distribución y la compilación de Bash — donde eso importa, se aclara.

Todos los artefactos se crean bajo `/tmp/lab103` y `~/bin`, y el Ejercicio 9 los elimina.

```bash
mkdir -p /tmp/lab103
cd /tmp/lab103
pwd
```

Salida esperada:

```
/tmp/lab103
```

> **Hábito de trabajo:** abrí una *segunda* terminal y dejá `man bash` abierto ahí. Casi todas las preguntas de abajo se responden desde esa página, y el examen premia saber *dónde* vive la respuesta.

---

## Ejercicio 1 — Identificar qué shell estás ejecutando realmente

La línea de comandos es un *proceso*. Antes de cambiar su comportamiento, comprobá cuál es ese proceso.

1. Mostrá el ID de proceso de la shell y el de su padre:

   ```bash
   echo "$$"
   ps -p "$$" -o pid,ppid,comm
   ```

   Salida esperada (los números van a diferir):

   ```
   4711
       PID    PPID COMMAND
      4711    4702 bash
   ```

2. Preguntale a Bash por su propia versión, de dos maneras distintas:

   ```bash
   echo "$BASH_VERSION"
   bash --version | head -n 1
   ```

   Salida esperada:

   ```
   5.2.21(1)-release
   GNU bash, version 5.2.21(1)-release (x86_64-pc-linux-gnu)
   ```

3. Mirá `$0`, y después compará con una login shell:

   ```bash
   echo "$0"
   bash -l -c 'echo "$0"'
   ```

   Salida esperada:

   ```
   bash
   -bash
   ```

4. Identificá el kernel y el hardware de la máquina, que es lo que reporta `uname` — **no** la distribución:

   ```bash
   uname
   uname -s -r -m
   uname -a
   ```

   Salida esperada (recortada):

   ```
   Linux
   Linux 6.8.0-45-generic x86_64
   Linux studybox 6.8.0-45-generic #45-Ubuntu SMP ... x86_64 GNU/Linux
   ```

5. Compará eso con el archivo de identidad de la propia distribución:

   ```bash
   cat /etc/os-release | head -n 3
   ```

**Comprobá lo aprendido**

- **Q1.1** — ¿Por qué `bash -l -c 'echo "$0"'` imprime `-bash` en vez de `bash`? ¿Qué consume ese guion inicial, y qué decide?
- **Q1.2** — `uname -r` reporta `6.8.0-45-generic`, pero `/etc/os-release` dice `Ubuntu 24.04`. Explicá con precisión qué describe cada valor y por qué uno no se puede derivar del otro.
- **Q1.3** — `$$` es una variable de shell. Predecí la salida de `echo "$$"` frente a `bash -c 'echo "$$"'` ejecutados desde la misma shell, y justificá la diferencia.

---

## Ejercicio 2 — Cómo decide Bash *qué* ejecutar

Cuando escribís una palabra, Bash la resuelve en un orden fijo: **alias → función → builtin → ruta hasheada → búsqueda en `PATH`**. Este ejercicio hace visible ese orden.

1. Inspeccioná el tipo de varios comandos:

   ```bash
   type -t if
   type -t cd
   type -t ls
   type -t bash
   ```

   Salida esperada (en una distribución típica donde `ls` está aliasado):

   ```
   keyword
   builtin
   alias
   file
   ```

2. Mostrá *todos* los candidatos para un nombre, en orden de resolución:

   ```bash
   type -a echo
   ```

   Salida esperada:

   ```
   echo is a shell builtin
   echo is /usr/bin/echo
   echo is /bin/echo
   ```

3. Contrastá las tres herramientas de búsqueda:

   ```bash
   type echo
   command -v echo
   which echo
   ```

   Salida esperada:

   ```
   echo is a shell builtin
   echo
   /usr/bin/echo
   ```

4. Creá una colisión deliberada — una *función* que tapa un comando externo:

   ```bash
   pwd() { echo "I am a function, not the real pwd"; }
   pwd
   type -a pwd
   command pwd
   /bin/pwd
   unset -f pwd
   pwd
   ```

   Salida esperada:

   ```
   I am a function, not the real pwd
   pwd is a function
   pwd ()
   {
       echo "I am a function, not the real pwd"
   }
   pwd is a shell builtin
   pwd is /usr/bin/pwd
   /tmp/lab103
   /tmp/lab103
   /tmp/lab103
   ```

5. Observá la **tabla hash** — la caché de Bash con las búsquedas de `PATH` ya resueltas:

   ```bash
   hash -r
   hash
   date > /dev/null; date > /dev/null; ls > /dev/null
   hash
   ```

   Salida esperada:

   ```
   hash: hash table empty
   hits	command
      2	/usr/bin/date
      1	/usr/bin/ls
   ```

**Comprobá lo aprendido**

- **Q2.1** — Reproducí el orden de resolución completo. ¿En qué paso se maneja una *keyword* de shell como `if`, y por qué nunca puede ser sobrescrita por un archivo en `PATH`?
- **Q2.2** — `which echo` dice `/usr/bin/echo`, pero al escribir `echo` se ejecuta el builtin. Explicá por qué `which` da una respuesta engañosa acá, y nombrá el reemplazo correcto según POSIX.
- **Q2.3** — Después de `pwd() { ...; }`, tanto `command pwd` como `/bin/pwd` esquivan la función, pero *no* son equivalentes. ¿Cuál es la diferencia?
- **Q2.4** — Movés `/usr/bin/date` a `/usr/local/bin/date` y después `date` falla con `No such file or directory` aunque la nueva ubicación está en `PATH`. ¿Qué lo causó, y qué único comando lo arregla?

---

## Ejercicio 3 — Invocar comandos dentro y fuera de `PATH`

1. Mirá tu ruta de búsqueda, una entrada por línea:

   ```bash
   echo "$PATH"
   echo "$PATH" | tr ':' '\n'
   ```

2. Creá un comando personal. Fijate en el delimitador **entrecomillado** del here-document:

   ```bash
   mkdir -p ~/bin
   cat > ~/bin/greet <<'EOF'
   #!/bin/bash
   echo "greet: script=$0 pid=$$ user=$USER"
   EOF
   chmod +x ~/bin/greet
   ls -l ~/bin/greet
   ```

   Salida esperada:

   ```
   -rwxr-xr-x 1 student student 62 Aug 26 10:14 /home/student/bin/greet
   ```

3. Intentá ejecutarlo por nombre pelado, y después por ruta:

   ```bash
   greet
   ~/bin/greet
   /home/"$USER"/bin/greet
   ```

   Salida esperada (asumiendo que `~/bin` todavía no está en `PATH`):

   ```
   bash: greet: command not found
   greet: script=/home/student/bin/greet pid=4802 user=student
   greet: script=/home/student/bin/greet pid=4803 user=student
   ```

4. Agregá el directorio a `PATH` y reintentá:

   ```bash
   export PATH="$HOME/bin:$PATH"
   greet
   type greet
   ```

   Salida esperada:

   ```
   greet: script=/home/student/bin/greet pid=4810 user=student
   greet is /home/student/bin/greet
   ```

5. Ahora creá un *segundo* `greet` en el directorio actual y observá que **no** es el que se elige:

   ```bash
   cd /tmp/lab103
   printf '#!/bin/bash\necho "greet: LOCAL copy"\n' > greet
   chmod +x greet
   greet
   ./greet
   ```

   Salida esperada:

   ```
   greet: script=/home/student/bin/greet pid=4820 user=student
   greet: LOCAL copy
   ```

6. Quitá el bit de ejecución y observá el error distinto:

   ```bash
   chmod -x greet
   ./greet
   bash greet
   ```

   Salida esperada:

   ```
   bash: ./greet: Permission denied
   greet: LOCAL copy
   ```

**Comprobá lo aprendido**

- **Q3.1** — ¿Por qué hace falta `./greet`, mientras que `greet` solo no alcanza? ¿Qué se rompería si `.` estuviera en `PATH`?
- **Q3.2** — En el paso 6, `./greet` falla con *Permission denied* pero `bash greet` funciona. ¿Qué bit de permisos requiere realmente cada invocación, y por qué difieren?
- **Q3.3** — `export PATH="$HOME/bin:$PATH"` se ejecutó en una terminal. Abrí una terminal nueva y ejecutá `type greet`. ¿Qué pasa, y dónde tiene que ir esa línea para que sea permanente en shells interactivas?
- **Q3.4** — ¿Cuál es la diferencia práctica entre `PATH="$HOME/bin:$PATH"` y `PATH="$PATH:$HOME/bin"`? Dá un escenario donde la elección cambie qué binario se ejecuta.

---

## Ejercicio 4 — Variables de shell vs. variables de entorno

Esta es la distinción que más se toma en 103.1.

1. Creá una variable **de shell** común — ojo: sin espacios alrededor del `=`:

   ```bash
   MYVAR=hello
   echo "$MYVAR"
   ```

   Después observá qué hace la sintaxis equivocada:

   ```bash
   MYVAR = hello
   ```

   Salida esperada:

   ```
   hello
   bash: MYVAR: command not found
   ```

2. Preguntale a dos herramientas distintas si la variable existe:

   ```bash
   set | grep '^MYVAR='
   env | grep '^MYVAR='
   echo "env exit status: $?"
   ```

   Salida esperada:

   ```
   MYVAR=hello
   env exit status: 1
   ```

3. Comprobá que un proceso hijo no la ve, después exportala y reintentá:

   ```bash
   bash -c 'echo "child sees: [$MYVAR]"'
   export MYVAR
   bash -c 'echo "child sees: [$MYVAR]"'
   env | grep '^MYVAR='
   ```

   Salida esperada:

   ```
   child sees: []
   child sees: [hello]
   MYVAR=hello
   ```

4. Inspeccioná los atributos de la variable directamente:

   ```bash
   declare -p MYVAR
   export -n MYVAR
   declare -p MYVAR
   export MYVAR
   ```

   Salida esperada:

   ```
   declare -x MYVAR="hello"
   declare -- MYVAR="hello"
   ```

5. Definí una variable **para un solo comando**, y confirmá que el padre queda intacto:

   ```bash
   MYVAR=temporary bash -c 'echo "child: $MYVAR"'
   echo "parent: $MYVAR"
   env MYVAR=viaenv bash -c 'echo "child: $MYVAR"'
   echo "parent: $MYVAR"
   ```

   Salida esperada:

   ```
   child: temporary
   parent: hello
   child: viaenv
   parent: hello
   ```

6. Demostrá que el hijo recibe una **copia**, no una referencia:

   ```bash
   bash -c 'MYVAR=changed_by_child; echo "child now: $MYVAR"'
   echo "parent still: $MYVAR"
   ```

   Salida esperada:

   ```
   child now: changed_by_child
   parent still: hello
   ```

7. Arrancá un proceso con el entorno **limpiado**:

   ```bash
   env -i printenv | wc -l
   env -i bash -c 'echo "PATH=[$PATH]"'
   ```

   Salida esperada:

   ```
   0
   PATH=[/usr/local/bin:/usr/bin:/bin:/usr/local/games:/usr/games]
   ```

   (El `PATH` exacto varía — es el valor por defecto compilado en Bash, no un valor heredado.)

8. Eliminá la variable, y notá que `unset` tiene dos espacios de nombres:

   ```bash
   unset -v MYVAR
   echo "[${MYVAR}]"
   readonly RO=locked
   unset -v RO
   ```

   Salida esperada:

   ```
   []
   bash: unset: RO: cannot unset: readonly variable
   ```

**Comprobá lo aprendido**

- **Q4.1** — Enunciá la diferencia exacta entre una variable de shell y una variable de entorno, en términos de qué transfieren `fork()`/`exec()` al hijo.
- **Q4.2** — `set | grep MYVAR` la encuentra, `env | grep MYVAR` no. ¿Cuál lista qué espacio de nombres, y qué *otra cosa* imprime `set` a secas que `env` jamás va a imprimir?
- **Q4.3** — En el paso 7, `env -i` limpió el entorno y sin embargo el Bash hijo reportó un `PATH` no vacío. ¿De dónde salió ese valor? ¿Por qué importa esto al depurar un trabajo de cron?
- **Q4.4** — Un colega define `EDITOR=vim` en su shell y se queja de que `sudo visudo` sigue abriendo `nano`. Dá dos razones independientes por las que esto puede pasar, y el comando que prueba cuál aplica.
- **Q4.5** — ¿Por qué `MYVAR=temporary bash -c '...'` no deja `MYVAR` alterada en el padre, mientras que `export MYVAR=temporary; bash -c '...'` sí lo haría?

---

## Ejercicio 5 — Quoting: el mecanismo, no el folclore

1. Creá un archivo cuyo nombre contenga un espacio, y después rompelo:

   ```bash
   cd /tmp/lab103
   file="my report.txt"
   touch "$file"
   ls -l $file
   ls -l "$file"
   ```

   Salida esperada:

   ```
   ls: cannot access 'my': No such file or directory
   ls: cannot access 'report.txt': No such file or directory
   -rw-r--r-- 1 student student 0 Aug 26 10:20 'my report.txt'
   ```

2. Observá la expansión de la shell con la traza de ejecución:

   ```bash
   set -x
   ls -l $file
   ls -l "$file"
   set +x
   ```

   Salida esperada (las líneas de traza empiezan con `+`):

   ```
   + ls -l my report.txt
   ...
   + ls -l 'my report.txt'
   ```

3. Compará los tres mecanismos de quoting contra la misma cadena:

   ```bash
   echo 'Home is $HOME and the date is $(date +%F)'
   echo "Home is $HOME and the date is $(date +%F)"
   echo Home is \$HOME
   ```

   Salida esperada:

   ```
   Home is $HOME and the date is $(date +%F)
   Home is /home/student and the date is 2026-08-26
   Home is $HOME
   ```

4. Probá qué siguen dejando pasar las comillas *dobles*:

   ```bash
   touch a.txt b.txt
   echo *.txt
   echo "*.txt"
   echo "user=$USER host=$(hostname) sum=$((6*7))"
   ```

   Salida esperada:

   ```
   a.txt b.txt my report.txt
   *.txt
   user=student host=studybox sum=42
   ```

5. Resolvé el problema de la comilla simple dentro de comillas simples:

   ```bash
   echo "it's fine"
   echo 'it'\''s fine'
   echo $'tab\there\nnewline done'
   ```

   Salida esperada:

   ```
   it's fine
   it's fine
   tab	here
   newline done
   ```

6. Usá una barra invertida como **continuación de línea** en una secuencia de una sola línea:

   ```bash
   echo "first part" \
        "second part"
   ```

   Salida esperada:

   ```
   first part second part
   ```

7. Observá la consecuencia de una variable sin comillas que contiene un valor vacío:

   ```bash
   empty=""
   ls -l $empty
   ls -l "$empty"
   ```

   Salida esperada: el primero lista el directorio actual; el segundo reporta

   ```
   ls: cannot access '': No such file or directory
   ```

**Comprobá lo aprendido**

- **Q5.1** — Enumerá, en orden, las expansiones que realiza Bash sobre una línea de comandos. ¿En qué paso ocurre el word splitting, y por qué eso hace que `ls -l $file` falle mientras `ls -l "$file"` funciona?
- **Q5.2** — ¿Qué caracteres conservan su significado especial **dentro** de comillas dobles? ¿Y dentro de comillas simples?
- **Q5.3** — ¿Por qué una cadena entre comillas simples nunca puede contener una comilla simple, ni siquiera escapada?
- **Q5.4** — En el paso 7, `$empty` sin comillas produjo *cero* argumentos mientras que `"$empty"` produjo *un argumento vacío*. Explicá el mecanismo, y describí un escenario donde esto convierta un script inofensivo en uno destructivo.
- **Q5.5** — `echo "*.txt"` imprimió el glob literal. ¿Qué entidad realiza la expansión de nombres de ruta — la shell o `echo`? ¿Qué recibe `echo` en cada caso?

---

## Ejercicio 6 — Secuencias de comandos en una línea y estado de salida

1. Leé el estado de salida directamente:

   ```bash
   true;  echo "status=$?"
   false; echo "status=$?"
   ls /nonexistent 2>/dev/null; echo "status=$?"
   ```

   Salida esperada:

   ```
   status=0
   status=1
   status=2
   ```

2. Compará los tres separadores:

   ```bash
   false ; echo "semicolon: always runs"
   false && echo "AND: not printed"
   false || echo "OR: printed"
   true  && echo "AND: printed"
   ```

3. Encadená una secuencia realista:

   ```bash
   mkdir -p /tmp/lab103/out && cd /tmp/lab103/out && pwd && cd - >/dev/null
   grep -q '^root:' /etc/passwd && echo "root present" || echo "root missing"
   ```

   Salida esperada:

   ```
   /tmp/lab103/out
   root present
   ```

4. Exponé la trampa clásica de `&& ... || ...`:

   ```bash
   true && ls /nonexistent 2>/dev/null || echo "fallback ran"
   ```

   Salida esperada:

   ```
   fallback ran
   ```

5. Contrastá una **subshell** con un **comando de grupo**:

   ```bash
   cd /tmp/lab103
   pwd ; ( cd /tmp && pwd ) ; pwd
   pwd ; { cd /tmp && pwd ; } ; pwd
   cd /tmp/lab103
   ```

   Salida esperada:

   ```
   /tmp/lab103
   /tmp
   /tmp/lab103
   /tmp/lab103
   /tmp
   /tmp
   ```

6. Mostrá que las variables definidas en una subshell no sobreviven:

   ```bash
   V=outer
   ( V=inner; echo "inside: $V" )
   echo "outside: $V"
   ```

   Salida esperada:

   ```
   inside: inner
   outside: outer
   ```

7. Leé el estado de salida de un **pipeline**:

   ```bash
   false | true ; echo "pipeline status=$?"
   echo "each stage: ${PIPESTATUS[@]}"
   set -o pipefail
   false | true ; echo "with pipefail=$?"
   set +o pipefail
   ```

   Salida esperada:

   ```
   pipeline status=0
   each stage: 1 0
   with pipefail=1
   ```

8. Armá un one-liner genuinamente útil:

   ```bash
   cut -d: -f7 /etc/passwd | sort | uniq -c | sort -rn | head -n 5
   ```

   Salida esperada (los valores varían):

   ```
        28 /usr/sbin/nologin
         3 /bin/false
         2 /bin/sync
         1 /bin/bash
   ```

**Comprobá lo aprendido**

- **Q6.1** — Dá la convención de estado de salida: qué valor significa éxito, y qué rango está disponible para el fallo. ¿Qué indica específicamente el estado `127`, y el `126`?
- **Q6.2** — Explicá el paso 4. ¿Por qué `A && B || C` **no** es un if/then/else seguro, y cuál es la construcción correcta?
- **Q6.3** — ¿Por qué `( cd /tmp )` dejó el directorio del llamador sin cambios mientras que `{ cd /tmp; }` no? ¿Cuál de las dos hace fork?
- **Q6.4** — Por defecto, `$?` después de un pipeline reporta el estado de una sola etapa. ¿De cuál, y cuáles son los dos mecanismos mostrados para ver el resto?
- **Q6.5** — En el paso 8, ¿cuántos procesos crea la shell, y se ejecutan de forma secuencial o concurrente?

---

## Ejercicio 7 — Historial de comandos

1. Inspeccioná el historial y su configuración:

   ```bash
   history | tail -n 5
   echo "HISTFILE=$HISTFILE"
   echo "HISTSIZE=$HISTSIZE  HISTFILESIZE=$HISTFILESIZE"
   echo "HISTCONTROL=$HISTCONTROL"
   ```

   Salida esperada:

   ```
      512  set +o pipefail
      513  cut -d: -f7 /etc/passwd | sort | uniq -c | sort -rn | head -n 5
      514  history | tail -n 5
   HISTFILE=/home/student/.bash_history
   HISTSIZE=1000  HISTFILESIZE=2000
   HISTCONTROL=ignoredups
   ```

2. Usá designadores de evento. `:p` **imprime sin ejecutar** — probá siempre primero con eso:

   ```bash
   echo alpha bravo charlie
   !!:p
   !!
   !echo:p
   ```

   Salida esperada:

   ```
   alpha bravo charlie
   echo alpha bravo charlie
   echo alpha bravo charlie
   alpha bravo charlie
   echo alpha bravo charlie
   ```

3. Usá designadores de palabra:

   ```bash
   ls -l /etc/hostname
   echo "last arg was: !$"
   echo "first arg was: !^"
   echo "all args were: !*"
   ```

   Salida esperada:

   ```
   -rw-r--r-- 1 root root 9 Aug 26 09:02 /etc/hostname
   echo "last arg was: /etc/hostname"
   last arg was: /etc/hostname
   ...
   ```

   (Bash muestra la línea expandida antes de ejecutarla — eso es la expansión de historial, no el comando.)

4. Recuperá por número y reparar un error de tipeo:

   ```bash
   history | tail -n 3
   !513
   grpe root /etc/passwd
   ^grpe^grep^
   ```

   Salida esperada:

   ```
   bash: grpe: command not found
   grep root /etc/passwd
   root:x:0:0:root:/root:/bin/bash
   ```

5. Practicá la búsqueda incremental de forma interactiva: presioná **`Ctrl-R`**, escribí `passwd`, presioná `Ctrl-R` de nuevo para ciclar hacia atrás, y después **`Ctrl-G`** para abortar sin ejecutar nada. Repetí y presioná **Enter** para ejecutar, o **`→`**/**`Ctrl-E`** para editar primero la línea recuperada.

6. Mantené un comando fuera del historial:

   ```bash
   HISTCONTROL=ignoreboth
   echo "this line is recorded"
    echo "this line is NOT recorded"
   history | tail -n 3
   ```

   (Fijate en el único **espacio inicial** del segundo `echo`.)

7. Agregá marcas de tiempo y comprobá que son metadatos de visualización:

   ```bash
   HISTTIMEFORMAT='%F %T  '
   history | tail -n 3
   ```

   Salida esperada:

   ```
      520  2026-08-26 10:31:44  echo "this line is recorded"
      521  2026-08-26 10:31:58  history | tail -n 3
   ```

8. Manipulá la lista de historial y el archivo:

   ```bash
   history | tail -n 1
   history -d 521
   wc -l < ~/.bash_history
   history -a
   wc -l < ~/.bash_history
   ```

9. Entendé la pérdida con múltiples terminales, y después arreglala:

   ```bash
   shopt histappend
   shopt -s histappend
   PROMPT_COMMAND='history -a'
   ```

10. Limpiá la lista en memoria y, por separado, el archivo:

    ```bash
    history -c
    history | wc -l
    ```

    Salida esperada:

    ```
    1
    ```

**Comprobá lo aprendido**

- **Q7.1** — Distinguí `HISTSIZE` de `HISTFILESIZE`. ¿Cuál se aplica cuando la shell termina?
- **Q7.2** — `history -c` devuelve una lista vacía, y sin embargo una terminal nueva vuelve a mostrar los comandos viejos. ¿Por qué? ¿Qué paso adicional los elimina realmente del disco?
- **Q7.3** — Explicá las cuatro opciones de escritura/lectura de `history` `-a`, `-w`, `-r`, `-n`, y por qué `shopt -s histappend` más `history -a` es el arreglo estándar para dos terminales que se sobrescriben entre sí.
- **Q7.4** — ¿Qué hacen `ignorespace`, `ignoredups`, `ignoreboth` y `erasedups` en `HISTCONTROL`? ¿Por qué *"poner un espacio antes del comando"* es una mala forma de ocultar una contraseña?
- **Q7.5** — `!!` funciona al escribirlo en el prompt pero no hace nada dentro de un script de shell. Explicá por qué, y nombrá la opción de shell involucrada.
- **Q7.6** — ¿A qué se expande `!$`, y cuál es el equivalente de Readline de una sola tecla que lo inserta sin pasar por la expansión de historial?

---

## Ejercicio 8 — Conseguir ayuda: `man` y compañía

1. Entendé las **secciones** del manual:

   ```bash
   man man | grep -A 12 'The table below'
   man 1 passwd
   man 5 passwd
   man -f passwd
   ```

   Salida esperada de `man -f`:

   ```
   passwd (1)           - change user password
   passwd (5)           - the password file
   passwd (1ssl)        - compute password hashes
   ```

2. Buscá por palabra clave — esto necesita la base de datos de índice:

   ```bash
   man -k 'change user password'
   apropos hostname | head -n 5
   whatis uname
   ```

   Salida esperada:

   ```
   passwd (1)           - change user password
   ...
   uname (1)            - print system information
   uname (2)            - get name and information about current kernel
   ```

   Si `man -k` reporta `nothing appropriate`, falta el índice; en la mayoría de los sistemas se reconstruye con `mandb` (como root) y se refresca mediante un temporizador periódico.

3. Localizá el archivo fuente y el origen de la página:

   ```bash
   man -w ls
   man -w 5 passwd
   ```

   Salida esperada:

   ```
   /usr/share/man/man1/ls.1.gz
   /usr/share/man/man5/passwd.5.gz
   ```

4. Pedí ayuda sobre un **builtin** — donde `man` normalmente falla:

   ```bash
   type -t cd
   help cd | head -n 5
   help -d export
   man cd
   ```

   Salida esperada:

   ```
   builtin
   cd: cd [-L|[-P [-e]] [-@]] [dir]
       Change the shell working directory.
   export - Set export attribute for shell variables.
   No manual entry for cd
   ```

5. Usá el tercer canal de ayuda — el flag propio del programa:

   ```bash
   ls --help | head -n 5
   uname --help | tail -n 5
   ```

6. Navegá una página con eficiencia (interactivo, dentro de `man ls`): `/` buscar hacia adelante, `n` siguiente coincidencia, `N` anterior, `G` final, `g` inicio, `q` salir. Probá:

   ```bash
   man ls
   ```

   y después escribí `/--human-readable` y presioná Enter.

7. Leé un concepto de Bash directamente desde la página fuente:

   ```bash
   man bash | grep -n 'QUOTING' | head -n 3
   ```

**Comprobá lo aprendido**

- **Q8.1** — Nombrá el propósito de las secciones 1, 5 y 8 del manual, y explicá por qué `passwd` aparece legítimamente en dos de ellas.
- **Q8.2** — `man -k ssh` devuelve `nothing appropriate` en un servidor recién instalado, y sin embargo `man ssh` funciona perfectamente. ¿Qué está roto, y qué lo arregla?
- **Q8.3** — Dá los tres canales de ayuda distintos demostrados acá e indicá cuál es el autoritativo para `cd`, `export` y `unset`. ¿Por qué `man` es la herramienta equivocada para esos?
- **Q8.4** — `whatis` y `man -f` produjeron la misma salida; lo mismo `apropos` y `man -k`. ¿Cuál es la relación real entre estos comandos?

---

## Ejercicio 9 — Integrador: diagnosticar una invocación rota

Un script falla por razones que combinan todo lo anterior. Construilo, rompelo, y después reparalo usando solamente los comandos de diagnóstico de este tema.

1. Armá el escenario:

   ```bash
   mkdir -p "/tmp/lab103/data files"
   touch "/tmp/lab103/data files/alpha.log" "/tmp/lab103/data files/beta.log"

   cat > /tmp/lab103/collect <<'EOF'
   #!/bin/bash
   echo "DATADIR=[$DATADIR]"
   ls -1 $DATADIR
   greet
   EOF
   chmod +x /tmp/lab103/collect
   ```

2. Ejecutalo como lo "probó" el autor:

   ```bash
   DATADIR="/tmp/lab103/data files"
   /tmp/lab103/collect
   ```

   Salida esperada — notá que *lista silenciosamente el directorio equivocado*:

   ```
   DATADIR=[]
   collect
   data files
   greet
   my report.txt
   ...
   greet: script=/home/student/bin/greet pid=5011 user=student
   ```

3. Reproducí el segundo fallo saneando el entorno:

   ```bash
   env PATH=/usr/bin:/bin DATADIR="/tmp/lab103/data files" /tmp/lab103/collect
   ```

   Salida esperada:

   ```
   DATADIR=[/tmp/lab103/data files]
   ls: cannot access '/tmp/lab103/data': No such file or directory
   ls: cannot access 'files': No such file or directory
   /tmp/lab103/collect: line 4: greet: command not found
   ```

4. Reuní evidencia antes de cambiar nada:

   ```bash
   declare -p DATADIR
   env | grep -c '^DATADIR='
   type greet
   bash -x /tmp/lab103/collect 2>&1 | head -n 8
   ```

5. Aplicá los tres arreglos:

   ```bash
   cat > /tmp/lab103/collect <<'EOF'
   #!/bin/bash
   : "${DATADIR:?DATADIR must be set and exported}"
   echo "DATADIR=[$DATADIR]"
   ls -1 "$DATADIR"
   PATH="$HOME/bin:$PATH"
   greet
   EOF
   chmod +x /tmp/lab103/collect

   export DATADIR="/tmp/lab103/data files"
   /tmp/lab103/collect
   ```

   Salida esperada:

   ```
   DATADIR=[/tmp/lab103/data files]
   alpha.log
   beta.log
   greet: script=/home/student/bin/greet pid=5044 user=student
   ```

6. Confirmá que la guarda funciona:

   ```bash
   env -u DATADIR /tmp/lab103/collect ; echo "status=$?"
   ```

   Salida esperada:

   ```
   /tmp/lab103/collect: line 2: DATADIR: DATADIR must be set and exported
   status=1
   ```

7. Limpieza:

   ```bash
   cd ~
   rm -rf /tmp/lab103
   rm -f ~/bin/greet
   unset -v DATADIR MYVAR file empty V
   hash -r
   ```

**Comprobá lo aprendido**

- **Q9.1** — En el paso 2 el script imprimió `DATADIR=[]` y después listó un directorio *distinto* en lugar de dar error. Rastreá ambas consecuencias hasta sus dos causas raíz independientes.
- **Q9.2** — En el paso 3, una variable (`DATADIR`) llegó al script y otra configuración (`PATH`) lo rompió. Explicá exactamente cómo `env PATH=... DATADIR=... cmd` compone el entorno del hijo.
- **Q9.3** — Se usó `bash -x` en lugar de `set -x`. ¿Cuándo preferirías cada uno, y qué prueba la traza que la depuración con `echo` no puede probar?
- **Q9.4** — El arreglo define `PATH` dentro del script sin `export`. ¿`greet` igual se resuelve? Justificá tu respuesta en términos de quién realiza la búsqueda en `PATH`.
- **Q9.5** — `: "${DATADIR:?message}"` es un idiom. ¿Qué hace el `:` inicial, qué hace `:?`, y en qué difiere el comportamiento de `${DATADIR:-default}` y `${DATADIR:=default}`?

---

<details>
<summary><strong>Respuestas</strong> — abrir solo después de intentar los ejercicios</summary>

### Ejercicio 1

**A1.1** — Una login shell se inicia con `argv[0]` puesto al nombre de la shell precedido por un guion; esa es la convención histórica que siguen `login`, `sshd`, `su -` y `bash -l`. Bash inspecciona `argv[0]` al arrancar: un `-` inicial marca a la shell como **login shell**, lo que cambia los archivos de inicio que lee (`/etc/profile`, después el primero que exista de `~/.bash_profile`, `~/.bash_login`, `~/.profile`, y `~/.bash_logout` al salir) en lugar del camino interactivo non-login (`~/.bashrc`). Nada "consume" el guion — es simplemente dato en `argv[0]` que Bash evalúa. Por eso los agregados a `PATH` puestos en `~/.bash_profile` aparecen en un login por SSH pero no en una pestaña de terminal nueva.

**A1.2** — `uname -r` reporta el **release del kernel** de la imagen de kernel en ejecución, obtenido de la syscall `uname(2)`. `/etc/os-release` describe la **distribución de userland** — el conjunto de paquetes, su versión y su proveedor — y es un archivo de texto plano sin ninguna intervención del kernel. Son independientes: el mismo userland de Ubuntu 24.04 puede correr un kernel de la distro, un kernel mainline o un kernel del proveedor; a la inversa, el mismo kernel 6.8 corre bajo userlands de Debian, Ubuntu o Fedora. Ninguno se puede derivar del otro. Consecuencia práctica: `uname -a` nunca te dice qué gestor de paquetes usar.

**A1.3** — `echo "$$"` imprime el PID de la **shell actual**. `bash -c 'echo "$$"'` hace fork y ejecuta un Bash nuevo, cuyo `$$` es su **propio** PID — un número distinto y mayor. `$$` lo expande la shell que está ejecutando el comando, y en el segundo caso las comillas simples impidieron que el padre lo expandiera, así que lo hizo el hijo. (Excepción sutil que vale la pena saber: dentro de una subshell `( ... )`, `$$` sigue reportando el PID del *padre*, porque Bash lo preserva deliberadamente; `$BASHPID` da el real.)

---

### Ejercicio 2

**A2.1** — Bash resuelve una palabra de comando en este orden:
1. **Palabra reservada / keyword** (`if`, `for`, `while`, `case`, `function`, `[[`, `time`, `{`) — reconocida por el *parser*, antes de que ocurra cualquier expansión o búsqueda.
2. **Alias** — sustitución textual, solo en shells interactivas por defecto.
3. **Función**.
4. **Builtin**.
5. **Ruta hasheada** — la ruta completa cacheada de una búsqueda previa exitosa en `PATH`.
6. **Búsqueda en `PATH`**, de izquierda a derecha, gana la primera coincidencia ejecutable.

Una keyword nunca puede ser sobrescrita por un archivo porque se consume durante el parseo para determinar la *gramática* del comando; para cuando podría ocurrir cualquier búsqueda, `if` ya no es un candidato a nombre de comando. Un archivo llamado `/usr/bin/if` solo es alcanzable por ruta completa o vía `command`/`env`.

**A2.2** — `which` es un **programa externo** (o en algunas distribuciones un script/alias de shell). Solo conoce `PATH`; no tiene visibilidad sobre los alias, funciones, builtins ni la tabla hash de la shell que lo llama, y su comportamiento y códigos de salida varían entre distribuciones. Responde "¿hay un archivo llamado `echo` en `PATH`?" — una pregunta distinta de "¿qué va a ejecutar Bash?". Los reemplazos correctos según POSIX son `command -v NAME` (legible por máquina: imprime una ruta, una definición de alias, o el nombre pelado para builtins/keywords) y `type NAME` / `type -a NAME` (legible por humanos, muestra todos los candidatos en orden).

**A2.3** — `command pwd` saltea **alias y funciones** pero igual usa la resolución normal de builtin/`PATH`, así que ejecuta el **builtin `pwd`**. `/bin/pwd` esquiva la resolución por completo y ejecuta el **binario de coreutils** en un proceso nuevo. La distinción es observable: el builtin reporta el `$PWD` lógico propio de Bash (los symlinks se preservan) por defecto, mientras que `/bin/pwd` también usa modo lógico por defecto pero es un proceso aparte con su propio comportamiento de `getcwd()` bajo `-P`. En la práctica, `command` es más barato (sin `fork`/`exec`) y es la herramienta correcta para vencer a una función; la ruta absoluta es la herramienta correcta cuando tenés que garantizar la implementación externa.

**A2.4** — La **tabla hash** de Bash cacheó la ubicación vieja `/usr/bin/date` de la búsqueda exitosa anterior, y reintenta esa ruta obsoleta en lugar de volver a buscar en `PATH`. Arreglo: `hash -r` (o `hash -d date` para una sola entrada) limpia la caché y fuerza una búsqueda nueva. `hash -r` es también el reflejo después de instalar un paquete en un directorio que ya buscaste sin éxito.

---

### Ejercicio 3

**A3.1** — Bash solo busca en `PATH` las palabras de comando que **no contienen barra**. Una palabra que contiene una barra se trata como un nombre de ruta y se usa directamente. Dado que `.` no está en `PATH` en un sistema correctamente configurado, la palabra pelada `greet` dispara una búsqueda en `PATH` que no encuentra el archivo local; `./greet` contiene una barra, así que se usa tal cual. Agregar `.` a `PATH` es un vector de escalada de privilegios muy conocido: un atacante que puede escribir en un directorio compartido o escribible por todos (`/tmp`, un directorio de subidas) planta un archivo llamado `ls` o `sl`, y cualquier usuario que haga `cd` ahí y ejecute `ls` lo ejecuta. El riesgo es peor cuando `.` está *primero* en `PATH` y cuando la víctima es root.

**A3.2** — `./greet` le pide al **kernel** que haga `execve()` del archivo, lo que requiere el bit de **ejecución** para el usuario que llama; el kernel entonces lee la línea `#!` y ejecuta el intérprete. Sin `x`, `execve()` devuelve `EACCES` y Bash imprime *Permission denied*. `bash greet` ejecuta `/usr/bin/bash` (que tiene `x`) y le pasa `greet` como argumento; Bash entonces solo necesita **leer** el archivo, así que alcanza con el bit `r`. Corolario: la línea `#!` es irrelevante en la segunda forma — `bash greet` ejecutaría un script cuyo shebang dice `#!/usr/bin/python3`.

**A3.3** — La terminal nueva imprime `bash: type: greet: not found`. `export` modifica solamente la shell actual y los hijos que esta lance después; no puede alcanzar terminales hermanas ni futuras. Para hacerlo permanente en shells interactivas non-login, agregá `export PATH="$HOME/bin:$PATH"` a `~/.bashrc`; para login shells (SSH, consola, `su -`) agregalo a `~/.bash_profile` — el patrón habitual es ponerlo en `~/.bashrc` y hacer que `~/.bash_profile` haga source de `~/.bashrc`. Notá que muchas distribuciones ya agregan `~/bin` a `PATH` desde `~/.profile` **si el directorio existe al momento del login**, y por eso crear `~/bin` a veces parece funcionar recién después de volver a iniciar sesión.

**A3.4** — `PATH` se recorre de izquierda a derecha, gana la primera coincidencia. Anteponer (`"$HOME/bin:$PATH"`) significa que tus copias **tapan** los comandos del sistema; agregar al final significa que ganan los comandos del sistema y los tuyos son solo un respaldo. Escenario: ponés en `~/bin` un wrapper llamado `kubectl` que inyecta un flag `--context`. Anteponiéndolo, cada invocación usa tu wrapper. Agregándolo al final, `/usr/bin/kubectl` se encuentra primero y el wrapper es código muerto. Anteponer es cómodo pero también es la forma en que un `~/bin` comprometido secuestra silenciosamente cada comando que escribís — el compromiso de seguridad es el mismo que con `.` en `PATH`, solo que más lento de explotar.

---

### Ejercicio 4

**A4.1** — Una **variable de shell** vive en la memoria del propio proceso de la shell. Una **variable de entorno** es una variable de shell marcada además con el atributo *export*, lo que hace que Bash la coloque en el arreglo `envp` pasado a `execve()` cuando lanza un hijo. El runtime de C del hijo expone ese arreglo como `environ`, y su propia shell (si es una shell) convierte cada entrada de vuelta en una variable exportada. Así que `export` no "comparte" nada: inscribe a la variable en la **copia unidireccional** hecha al momento del `exec()`. Un hijo nunca puede escribir de vuelta en el entorno del padre — los únicos canales son el estado de salida, los flujos de salida, archivos e IPC.

**A4.2** — `set` sin argumentos lista el espacio de nombres **completo** de variables de la shell — exportadas *y* no exportadas — más **todas las funciones de shell definidas** con sus cuerpos. `env` (y `printenv`) lista solo el **entorno exportado** que heredaría un hijo. Las funciones y las variables no exportadas nunca aparecen en `env`. Exactamente por eso `set | grep MYVAR` coincidió y `env | grep MYVAR` no devolvió nada con estado de salida 1 (grep no encontró coincidencia). En la práctica, `declare -p NAME` es la herramienta precisa: `declare -x` significa exportada, `declare --` significa solo de shell.

**A4.3** — Cuando Bash arranca y no encuentra `PATH` en el entorno heredado, inicializa `PATH` desde un **valor por defecto compilado** (`DEFAULT_PATH_VALUE`, elegido en tiempo de compilación por la distribución). Ese valor suele ser mucho más corto que un `PATH` de login y frecuentemente omite `/usr/local/bin`, `/sbin`, `/usr/sbin` y `~/bin`. Esta es la explicación canónica de *"el script funciona en mi terminal pero falla en cron"*: `cron` arranca los trabajos con un entorno mínimo (habitualmente `PATH=/usr/bin:/bin`, `HOME`, `SHELL`, `LOGNAME` y nada más), **no** lee `~/.bashrc` ni `~/.bash_profile`, y por eso cualquier comando fuera de ese `PATH` esquelético falla con *command not found*. `env -i` es la forma correcta de reproducir ese fallo de manera interactiva. Arreglo: usar rutas absolutas en los trabajos de cron, o definir `PATH` explícitamente al inicio del script/crontab.

**A4.4** — Dos causas independientes:
1. **`EDITOR` nunca fue exportada.** Existe como variable de shell, así que `echo $EDITOR` imprime `vim` en la shell, pero `sudo` — un proceso hijo — nunca la recibe. Prueba: `declare -p EDITOR` muestra `declare -- EDITOR="vim"` en lugar de `declare -x`.
2. **`sudo` la limpió.** Por defecto `sudo` reinicia el entorno según `env_reset` y solo pasa las variables listadas en `env_keep` en `/etc/sudoers`. Incluso una `EDITOR` correctamente exportada se descarta salvo que se defina `env_keep += "EDITOR"` — y `visudo` consulta específicamente `SUDO_EDITOR`, luego `VISUAL`, luego `EDITOR`. Prueba: `sudo printenv EDITOR` no imprime nada mientras `printenv EDITOR` imprime `vim`, y `sudo -V | grep -i env_keep` muestra la política.

El único diagnóstico que las separa es `declare -p EDITOR`: si le falta `-x`, causa 1; si tiene `-x` y `sudo printenv EDITOR` sigue vacío, causa 2.

**A4.5** — `MYVAR=temporary bash -c '...'` es una **asignación de variable como prefijo de un comando**. POSIX define esta forma para colocar la asignación en el *entorno de ese comando solamente*; la variable de la shell actual queda intacta (para builtins regulares y comandos externos). `export MYVAR=temporary`, en cambio, realiza una asignación común en la shell actual *y* establece el atributo de export, así que el cambio persiste en el padre para todos los comandos posteriores. La forma de prefijo es el idiom correcto para sobrescrituras puntuales — `LC_ALL=C sort file`, `DEBUG=1 ./run.sh` — precisamente porque no puede filtrarse.

---

### Ejercicio 5

**A5.1** — Bash realiza las expansiones en este orden fijo:
1. Expansión de llaves (`{a,b}`)
2. Expansión de tilde (`~`)
3. Expansión de parámetros y variables (`$VAR`, `${VAR}`)
4. Sustitución de comandos (`$(...)`, backticks)
5. Expansión aritmética (`$((...))`)
6. **Word splitting** — sobre los caracteres de `IFS` (por defecto: espacio, tabulador, salto de línea)
7. Expansión de nombres de ruta / globbing (`*`, `?`, `[...]`)
8. Eliminación de comillas

El word splitting ocurre en el paso 6, **después** de que la variable ya fue reemplazada por su texto. Así que `ls -l $file` se convierte en `ls -l my report.txt`, que después se divide en dos palabras y se le pasa a `ls` como dos argumentos separados. Las comillas dobles suprimen los pasos 6 y 7 para el texto encerrado, así que `"$file"` sobrevive como un único argumento que contiene un espacio. La regla que se desprende: **entrecomillá toda expansión de variable salvo que específicamente quieras splitting y globbing.**

**A5.2** — Dentro de **comillas dobles**, estos conservan su significado especial: `$` (expansión de parámetros, de comandos y aritmética), `` ` `` (sustitución de comandos heredada), `\` (solo antes de `$`, `` ` ``, `"`, `\` o un salto de línea — en otro lugar es literal), y `!` (expansión de historial, solo en shells interactivas). El word splitting y el globbing están deshabilitados. Dentro de **comillas simples**, *nada* es especial — cada carácter, incluidos `$`, `` ` ``, `\`, `!`, `*` y el salto de línea, es literal.

**A5.3** — El procesamiento de comillas simples está definido como "consumir caracteres literalmente hasta la siguiente `'`". No hay mecanismo de escape adentro, porque `\` ahí mismo es literal — así que la primerísima `'` encontrada *siempre* termina la cadena. Para incluir una tenés que salir de la región entrecomillada: `'it'\''s'` es la concatenación de `'it'` + `\'` (una comilla escapada, fuera de comillas) + `'s'`, que la shell une en una única palabra `it's`. Alternativas: `"it's"` o `$'it\'s'`.

**A5.4** — Después de la expansión de parámetros, `$empty` se convierte en la cadena vacía; el word splitting sobre una cadena vacía produce **cero palabras**, así que el argumento desaparece por completo y `ls -l` se ejecuta sin operando, tomando `.` por defecto. `"$empty"` está protegida del splitting, así que sobrevive como un argumento que resulta estar vacío, y `ls` reporta fielmente que no puede acceder a `''`. El escenario destructivo es el mismo mecanismo con un comando distinto: en un script, `rm -rf $PREFIX/$DIR` con ambas variables sin definir se expande a `rm -rf /` — el argumento no se volvió vacío, se volvió el directorio raíz. Entrecomillar convierte eso en un error inofensivo (`cannot remove '/'`); `set -u` o `${PREFIX:?}` lo previenen de plano.

**A5.5** — La **shell** realiza la expansión de nombres de ruta, en el paso 7 de arriba, antes de que `echo` llegue a ejecutarse. Con `echo *.txt`, `echo` recibe tres argumentos separados (`a.txt`, `b.txt`, `my report.txt`) y simplemente los imprime separados por espacios. Con `echo "*.txt"`, el quoting suprimió el globbing, así que `echo` recibe el único argumento literal `*.txt`. Los comandos nunca ven el glob — un punto crítico cuando un comando implementa su *propio* pattern matching (`find -name '*.txt'`, `grep '*'`): ahí hay que entrecomillar con precisión para que la shell no expanda el patrón primero.

---

### Ejercicio 6

**A6.1** — El estado de salida `0` significa **éxito**; cualquier valor distinto de cero en `1`–`255` significa fallo, y el significado del valor específico lo define el programa (`ls` usa 1 para problemas menores y 2 para los serios; `grep` usa 1 para "ninguna línea coincidió" y 2 para un error real). Convenciones reservadas: **`127` = comando no encontrado** (falló la búsqueda en `PATH`), **`126` = encontrado pero no ejecutable** (permiso denegado, o es un directorio), `128+N` = terminado por la señal N (p. ej. `130` = SIGINT/`Ctrl-C`, `137` = SIGKILL). El estado del último comando en primer plano está en `$?`, y lo sobrescribe el comando *siguiente* — capturalo de inmediato si lo necesitás.

**A6.2** — `A && B || C` ejecuta `C` cuando falla **cualquiera** de las dos: `A` o `B`. En el paso 4, `true` tuvo éxito, así que `ls /nonexistent` se ejecutó y falló, y por eso disparó la rama `||` — el fallback se ejecutó aunque la "condición" era verdadera. Solo se comporta como if/then/else cuando `B` tiene éxito garantizado. La construcción correcta es un condicional real:

```bash
if true; then
    ls /nonexistent
else
    echo "fallback ran"
fi
```

**A6.3** — `( ... )` ejecuta su contenido en una **subshell**: Bash hace fork de un proceso hijo que hereda una copia del entorno, las variables, las funciones y el directorio actual. Cualquier `cd`, asignación de variable, `umask` o redirección adentro afecta solo a esa copia, que después termina. `{ ...; }` es un **comando de grupo**: lo ejecuta la shell *actual* sin ningún fork, así que sus efectos secundarios persisten. Solo la forma con paréntesis hace fork. Detalle de sintaxis que conviene memorizar: `{` y `}` son palabras reservadas, así que necesitan espacios alrededor y el último comando necesita un `;` o un salto de línea antes de `}`; `(` y `)` son operadores y no necesitan ninguno de los dos.

**A6.4** — Por defecto `$?` reporta el estado de salida del **último comando (el más a la derecha)** del pipeline — por eso `false | true` da 0 y por eso un `grep` que falla canalizado a `wc -l` parece exitoso. Dos mecanismos exponen el resto: el arreglo **`${PIPESTATUS[@]}`**, que contiene un estado por cada etapa del pipeline más reciente (el índice 0 es el más a la izquierda), y **`set -o pipefail`**, que hace que el pipeline devuelva el estado del comando más a la derecha que terminó con estado distinto de cero, o 0 si todos tuvieron éxito. `pipefail` es una extensión de Bash, no POSIX; `PIPESTATUS` debe leerse *inmediatamente*, ya que el comando siguiente lo reemplaza.

**A6.5** — Cinco: `cut`, `sort`, `uniq`, `sort`, `head` — la shell hace fork y exec de un proceso por etapa. Se ejecutan **concurrentemente**, no de manera secuencial: la shell crea todas las tuberías y todos los procesos por adelantado, conectando la salida estándar de cada etapa con la entrada estándar de la siguiente, y los buffers de tubería del kernel más las lecturas/escrituras bloqueantes proveen el control de flujo. Por eso la huella de memoria de un pipeline se mantiene acotada con entradas enormes, y por eso que `head` cierre temprano puede hacer que una etapa aguas arriba termine con SIGPIPE.

---

### Ejercicio 7

**A7.1** — `HISTSIZE` es la cantidad de comandos que se mantienen en la lista de historial **en memoria** de la shell en ejecución. `HISTFILESIZE` es la cantidad máxima de líneas que se mantienen en el **archivo de historial** (`$HISTFILE`, por defecto `~/.bash_history`). `HISTFILESIZE` se aplica cuando se escribe el archivo de historial — lo que normalmente ocurre cuando la shell **termina** — truncando el archivo a las N líneas más recientes. Poner cualquiera de las dos en una cadena vacía o en un valor negativo significa ilimitado. Notá que `HISTFILESIZE` se aplica *después* de agregar las entradas nuevas, así que un valor chico descarta silenciosamente historial viejo en cada salida.

**A7.2** — `history -c` limpia solamente la **lista en memoria** de la shell actual; nunca toca el archivo en disco. La terminal nueva lee `$HISTFILE` al arrancar, así que ve todo lo que se guardó previamente. Para borrar realmente el historial almacenado tenés que limpiar la lista en memoria *y* sobrescribir el archivo: `history -c && history -w`, o eliminar el archivo (`rm -f ~/.bash_history`) — pero cuidado, la shell actual lo va a reescribir al salir con lo que todavía tenga, así que limpiá la memoria primero. Una secuencia más cuidadosa: `history -c; history -w; unset HISTFILE` (lo último impide que la shell al salir escriba nada).

**A7.3** —
- `history -a` — **append**: agrega las entradas nuevas de esta sesión (las que todavía no se escribieron) a `$HISTFILE`.
- `history -w` — **write**: escribe toda la lista en memoria a `$HISTFILE`, *sobrescribiéndolo*.
- `history -r` — **read**: lee todo `$HISTFILE` y lo agrega a la lista en memoria.
- `history -n` — lee solo las líneas **nuevas** agregadas a `$HISTFILE` desde la última vez que esta shell lo leyó.

El comportamiento por defecto al salir se parece más a `-w`, así que con dos terminales abiertas la que sale **última** sobrescribe el archivo y los comandos de la otra desaparecen. `shopt -s histappend` cambia el comportamiento al salir para que agregue en vez de truncar, y `PROMPT_COMMAND='history -a'` vuelca cada comando al archivo apenas se ingresa en lugar de esperar a la salida — juntos hacen que las sesiones concurrentes acumulen en vez de pisarse. Agregar `history -n` a `PROMPT_COMMAND` además trae en vivo los comandos de la otra terminal.

**A7.4** —
- `ignorespace` — las líneas que empiezan con un espacio no se guardan.
- `ignoredups` — una línea idéntica a la *inmediatamente anterior* no se guarda.
- `ignoreboth` — abreviatura de las dos anteriores.
- `erasedups` — elimina todas las líneas coincidentes previas de la lista antes de guardar esta.

Anteponer un espacio es un mal mecanismo para ocultar secretos porque protege **solo el archivo de historial**: la contraseña sigue visible en la lista de procesos (`ps aux`, `/proc/<pid>/cmdline`) durante toda la vida del proceso, puede quedar registrada por auditd, por los logs de `sudo` o por hooks de auditoría de la shell, queda expuesta a todos los usuarios de la máquina, y la protección desaparece silenciosamente si `HISTCONTROL` no contiene `ignorespace` (no es el valor por defecto en todos lados). Tampoco hace nada respecto del scrollback de la terminal. Enfoques correctos: leer el secreto con `read -s`, tomarlo de un archivo con permisos restrictivos, o usar un credential helper — nunca como argumento en la línea de comandos.

**A7.5** — La expansión de historial (`!!`, `!$`, `!n`, `^old^new`) es una característica de **Readline/interactiva** controlada por la opción de shell `histexpand`, es decir `set -H`. Está **activada por defecto solo en shells interactivas** y desactivada en shells no interactivas como los scripts y `bash -c`. Esto es deliberado: un script que contuviera `!` dentro de una cadena sería reescrito de forma impredecible por lo que hubiera en el historial. También es la razón por la que `echo "hello!"` puede comportarse mal de manera interactiva pero nunca en un script, y por la que `set +H` es una línea razonable en un archivo rc interactivo si escribís `!` en cadenas a menudo.

**A7.6** — `!$` se expande al **último argumento del comando anterior** (equivalente a `!!:$`). El equivalente de Readline es **`Alt-.`** (o `Esc` y después `.`), *insert-last-argument*, que inserta el texto directamente en el buffer de edición — presionarlo repetidamente recorre hacia atrás los últimos argumentos de comandos anteriores. Es superior a `!$` porque ves el texto literal antes de ejecutar, y funciona incluso con la expansión de historial deshabilitada.

---

### Ejercicio 8

**A8.1** — La sección **1** es comandos de usuario (programas ejecutables y comandos de shell); la sección **5** es formatos de archivo y convenciones; la sección **8** es comandos de administración del sistema, normalmente con requerimiento de root. `passwd` aparece tanto en 1 como en 5 porque documentan objetos distintos que comparten nombre: `passwd(1)` es el programa `/usr/bin/passwd` que cambia una contraseña, y `passwd(5)` es el **formato de archivo** `/etc/passwd` — orden de campos, significados, y su relación con `/etc/shadow`. `man passwd` muestra la sección 1 porque `man` devuelve la primera coincidencia en el orden de secciones; tenés que decir `man 5 passwd` para llegar a la otra. (Para completar: 2 = syscalls, 3 = funciones de biblioteca, 4 = archivos especiales/dispositivos, 6 = juegos, 7 = misceláneas/convenciones.)

**A8.2** — `man -k` / `apropos` no leen las páginas de manual; consultan una **base de datos de índice pre-construida** con los nombres de las páginas y sus descripciones de una línea (entradas `whatis`), almacenada bajo `/var/cache/man`. En una instalación fresca, o después de instalar paquetes, esa base puede estar ausente o desactualizada, así que la búsqueda por palabra clave no encuentra nada mientras la consulta directa de la página — que recorre `MANPATH` y abre el archivo — sigue funcionando. Arreglo: construir el índice con `sudo mandb` (Debian/Ubuntu/Fedora) o `sudo makewhatis` en sistemas más viejos o derivados de BSD. La mayoría de las distribuciones además lo refrescan desde un temporizador de systemd o un trabajo de cron, y por eso el problema tiende a resolverse solo durante la noche.

**A8.3** — Los tres canales son:
1. **`man PAGE`** — la página de manual, para programas externos y formatos de archivo.
2. **`help BUILTIN`** — la documentación integrada de Bash, para builtins de la shell.
3. **`CMD --help`** — el texto de uso del propio programa, incrustado en el binario.

Para `cd`, `export` y `unset`, el autoritativo es **`help`**, porque son **builtins de la shell** — no tienen un archivo ejecutable propio, así que en general no hay nada que `man` pueda documentar (muchos sistemas no incluyen ninguna página, y donde existe una página `builtins(1)` esta simplemente redirige a `bash(1)`). Tienen que ser builtins por necesidad: `cd` tiene que cambiar el directorio de trabajo de la *shell actual*, y un proceso hijo nunca podría hacerlo; `export` y `unset` igualmente manipulan la propia tabla de variables de la shell. `--help` es el respaldo cuando un paquete no incluye ninguna página de manual, y es el único canal que garantiza coincidir con la versión del binario instalado.

**A8.4** — Son los mismos programas. `man -f` es funcionalmente idéntico a `whatis`: búsqueda de nombre exacto que devuelve la descripción de una línea de cada sección coincidente. `man -k` es idéntico a `apropos`: búsqueda por subcadena/regex sobre los nombres de página *y* las descripciones. En sistemas `man-db` modernos, `whatis` y `apropos` son literalmente el mismo ejecutable despachando según `argv[0]`, o wrappers finos alrededor de `man`. El examen espera que reconozcas ambas escrituras y que sepas que `-k` busca en las descripciones mientras que `-f` solo coincide con nombres.

---

### Ejercicio 9

**A9.1** — Dos causas raíz independientes:
1. **`DATADIR` nunca fue exportada.** Se asignó en la shell interactiva como una variable de shell común, así que no estaba en el `envp` pasado al Bash del script, y dentro del script `$DATADIR` se expandió a la cadena vacía — de ahí `DATADIR=[]`.
2. **`$DATADIR` no estaba entrecomillada.** Como la expansión era vacía y sin comillas, el word splitting produjo **cero** argumentos, así que `ls -1` se ejecutó sin operando y listó silenciosamente el **directorio de trabajo actual** en vez de fallar. Dos defectos separados conspiraron: la falta de export aportó el valor vacío, y la falta de comillas convirtió ese valor vacío en "ningún argumento" en lugar de en un error. Si `DATADIR` hubiera estado exportada pero sin comillas, esa misma línea habría dividido la ruta por su espacio y producido dos errores `cannot access` — que es exactamente lo que demostró el paso 3.

**A9.2** — `env PATH=/usr/bin:/bin DATADIR="..." /tmp/lab103/collect` ejecuta el programa externo `env`. `env` toma el entorno que heredó de la shell, aplica cada operando `NAME=VALUE` como agregado o **sobrescritura**, y después hace `execve()` del comando nombrado con ese entorno modificado. Así que el hijo recibió el entorno completo de la shell *excepto* que `PATH` fue reemplazado por el valor de dos directorios y `DATADIR` fue agregada. `~/bin` por lo tanto ya no estaba en la ruta de búsqueda, `greet` no se encontró (estado 127), mientras que `DATADIR` sí llegó al script. Notá que la shell expandió `"..."` antes de que `env` llegara a ejecutarse — `env` ve solo las cadenas finales. `env -i` parte de un entorno *vacío* en lugar del heredado, y `env -u NAME` elimina una sola variable.

**A9.3** — `bash -x script` habilita el trazado para una **invocación separada** del script sin editarlo, dejando el archivo intacto — lo correcto para diagnosticar el script de otra persona, un fallo puntual, o un script que no podés modificar. `set -x` dentro del script (o en tu shell interactiva) activa el trazado para una **región**, en pareja con `set +x` para desactivarlo — lo correcto cuando solo una sección es interesante y la salida completa sería ilegible. Lo que la traza prueba y `echo` no puede: muestra el comando **después de todas las expansiones y la eliminación de comillas**, exactamente como se va a ejecutar. `echo "$DATADIR"` te muestra un valor; `+ ls -1 /tmp/lab103/data files` te muestra que el valor se dividió en dos argumentos. Los límites entre argumentos, los argumentos vacíos y los resultados de globbing solo son visibles en la traza, y Bash entrecomilla amablemente las palabras trazadas que contienen caracteres especiales.

**A9.4** — Sí, `greet` igual se resuelve. La búsqueda en `PATH` la realiza la **shell que ejecuta el comando** — acá, el propio Bash del script — usando su propia **variable de shell** `PATH`. `export` solo importa para pasar el valor hacia *otros* procesos hijos. Así que `PATH="$HOME/bin:$PATH"` dentro del script alcanza para las búsquedas de comandos de ese mismo script; sería insuficiente solo si el script lanzara otro programa que a su vez necesitara `~/bin` en su entorno. En la práctica `PATH` casi siempre ya está exportada (heredada así desde el login), así que una asignación pelada actualiza la variable exportada existente y la distinción nunca aflora — pero entenderla es la diferencia entre adivinar y saber.

**A9.5** — Desglosándolo:
- **`:`** es el builtin nulo. Expande sus argumentos, pone `$?` en 0, y no hace nada más. Acá se usa puramente como soporte para que la expansión de parámetros se evalúe por su **efecto secundario** sin ejecutar ni imprimir nada.
- **`${VAR:?message}`** se expande a `$VAR` si está definida y no vacía; de lo contrario Bash escribe `VAR: message` en stderr y **termina** una shell no interactiva con estado distinto de cero (no termina una shell interactiva, solo aborta el comando). Esta es la guarda fail-fast.
- **`${VAR:-default}`** sustituye `default` solo para esta expansión; `VAR` sigue sin definir.
- **`${VAR:=default}`** sustituye `default` **y se la asigna** a `VAR`, así que persiste por el resto del script (esta forma falla con parámetros posicionales).

El prefijo `:` en cada forma significa "tratar vacío como no definido"; omitirlo (`${VAR-default}`, `${VAR?msg}`) hace que se dispare solo cuando la variable está genuinamente sin definir, dejando pasar un valor deliberadamente vacío. Elegí `:?` para entradas obligatorias, `:-` para valores opcionales con un respaldo, `:=` cuando el respaldo debe recordarse.

</details>