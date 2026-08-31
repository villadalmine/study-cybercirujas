# LPIC-1 · Tema 105.1 — Personalizar y usar el entorno del shell

## Ejercicios guiados

**Examen:** 102-500 (LPIC-1, versión 5.0) · **Peso:** 4 (total del Tema 105: 9)
**Cobertura del objetivo:** establecer variables de entorno al iniciar sesión y para shells nuevos, escribir funciones de Bash para secuencias de comandos usadas con frecuencia, mantener directorios esqueleto para cuentas nuevas, establecer la ruta de búsqueda de comandos.
**Utilidades evaluadas:** `.` , `source`, `/etc/bash.bashrc`, `/etc/profile`, `env`, `export`, `set`, `unset`, `~/.bash_profile`, `~/.bash_login`, `~/.profile`, `~/.bashrc`, `~/.bash_logout`, `function`, `alias`, `lists`.

---

### Requisitos del laboratorio y seguridad

Necesitás un sistema Linux descartable (VM o contenedor) con `bash` 4.4+ (preferentemente 5.x), acceso `sudo` o root, y `shadow-utils` (`useradd`). **No ejecutes esto en una máquina que te importe**: varios pasos rompen deliberadamente tus archivos de inicio del shell y crean usuarios de prueba.

Verificá tu intérprete y hacé una copia de respaldo antes que nada:

```bash
bash --version | head -1
mkdir -p ~/lab-105.1/backup
cp -av ~/.bashrc ~/.bash_profile ~/.bash_login ~/.profile ~/.bash_logout \
      ~/lab-105.1/backup/ 2>/dev/null
ls -A ~/lab-105.1/backup/
```

```text
GNU bash, version 5.2.26(1)-release (x86_64-pc-linux-gnu)
'/home/student/.bashrc' -> '/home/student/lab-105.1/backup/.bashrc'
'/home/student/.profile' -> '/home/student/lab-105.1/backup/.profile'
.bashrc  .profile
```

Cada ejercicio termina donde empezó; en el Ejercicio 10 se da un procedimiento completo de restauración.

---

## Ejercicio 1 — Clasificar el shell en el que estás sentado

Bash lee archivos de inicio *diferentes* según dos propiedades independientes y ortogonales: **interactivo o no**, y **de login o no**. Todo error de configuración en este tema empieza por equivocarse en esta clasificación.

**Paso 1.** Inspeccioná los flags de opciones actuales. La variable `$-` contiene los flags de una sola letra del shell en ejecución:

```bash
echo "$-"
```

```text
himBHs
```

La letra que importa es `i` (interactivo). Otras: `h` = `hashall`, `m` = control de trabajos, `B` = expansión de llaves, `H` = expansión del historial.

**Paso 2.** Preguntale directamente a Bash si es un shell de login. `login_shell` es una opción de `shopt` de solo lectura:

```bash
shopt login_shell
shopt -q login_shell; echo "exit status: $?"
```

```text
login_shell     off
exit status: 1
```

(En un emulador de terminal gráfico normalmente vas a ver `off`. Por SSH, en una consola de texto, o después de `su -`, vas a ver `on`.)

**Paso 3.** Mirá cómo fue invocado el proceso. Un shell de login se inicia convencionalmente con un guion antepuesto a `argv[0]`:

```bash
ps -o pid,ppid,args -p "$$"
```

```text
    PID    PPID COMMAND
   4412    4408 bash
```

**Paso 4.** Ahora producí deliberadamente las cuatro combinaciones y compará:

```bash
bash -c        'echo "non-login non-interactive: [$-]"'
bash -i -c     'echo "non-login interactive    : [$-]"'
bash -l -c     'echo "login non-interactive    : [$-]"'
bash -l -i -c  'echo "login interactive        : [$-]"'
```

```text
non-login non-interactive: [hBc]
non-login interactive    : [himBHc]
login non-interactive    : [hBc]
login interactive        : [himBHc]
```

**Paso 5.** Confirmá que `-l` realmente hizo algo, ya que `$-` no lo reporta:

```bash
bash -c   'shopt -q login_shell && echo LOGIN || echo NOT-LOGIN'
bash -l -c 'shopt -q login_shell && echo LOGIN || echo NOT-LOGIN'
```

```text
NOT-LOGIN
LOGIN
```

**Paso 6.** Compará un comando remoto con una sesión remota (salteá esto si `sshd` no está corriendo localmente):

```bash
ssh localhost 'echo "flags=[$-]"; shopt -q login_shell && echo LOGIN || echo NOT-LOGIN'
```

```text
flags=[hBc]
NOT-LOGIN
```

> **Q1.1** — ¿Qué letra única de `$-` prueba que el shell es interactivo, y por qué la propiedad login/no-login está *ausente* de `$-`?
> **Q1.2** — `su student` y `su - student` ambos te dan un shell como `student`. ¿Qué archivos de inicio difieren entre ellos, y por qué `su -` arregla el "mi PATH está mal después de cambiar de usuario"?
> **Q1.3** — `ssh localhost 'echo hi'` produjo un shell que no es ni de login ni interactivo. ¿Qué archivo de inicio lee Bash en ese caso, si es que lee alguno? (Hay dos respuestas defendibles — nombrá ambas.)
> **Q1.4** — ¿Por qué `ps -o args -p $$` es una forma poco confiable de detectar un shell de login comparada con `shopt -q login_shell`?

---

## Ejercicio 2 — Rastrear empíricamente el orden de los archivos de inicio

En lugar de memorizar el orden, instrumentá los archivos y dejá que Bash te lo diga.

**Paso 1.** Creá un marcador a nivel de sistema. `/etc/profile` hace source de todos los archivos `*.sh` en `/etc/profile.d/`, que es la ubicación soportada para drop-ins — nunca edites `/etc/profile` en sí:

```bash
sudo tee /etc/profile.d/00-lab-trace.sh >/dev/null <<'EOF'
echo "TRACE: /etc/profile.d/00-lab-trace.sh (via /etc/profile)" >&2
EOF
```

**Paso 2.** Instrumentá cada archivo por usuario. Notá que creamos los tres candidatos a archivo de login:

```bash
cd ~
printf 'echo "TRACE: ~/.bash_profile" >&2\n' >> ~/.bash_profile
printf 'echo "TRACE: ~/.bash_login"   >&2\n' >> ~/.bash_login
printf 'echo "TRACE: ~/.profile"      >&2\n' >> ~/.profile
printf 'echo "TRACE: ~/.bashrc"       >&2\n' >> ~/.bashrc
printf 'echo "TRACE: ~/.bash_logout"  >&2\n' >> ~/.bash_logout
ls -A ~/.bash* ~/.profile
```

```text
/home/student/.bash_login  /home/student/.bash_profile  /home/student/.bashrc
/home/student/.bash_logout /home/student/.profile
```

**Paso 3.** Iniciá un shell de login interactivo y salí inmediatamente:

```bash
bash -l -i -c 'true'
```

```text
TRACE: /etc/profile.d/00-lab-trace.sh (via /etc/profile)
TRACE: ~/.bash_profile
```

**Paso 4.** Quitá al ganador y repetí, dos veces:

```bash
mv ~/.bash_profile ~/lab-105.1/
bash -l -i -c 'true'
mv ~/.bash_login ~/lab-105.1/
bash -l -i -c 'true'
```

```text
TRACE: /etc/profile.d/00-lab-trace.sh (via /etc/profile)
TRACE: ~/.bash_login
TRACE: /etc/profile.d/00-lab-trace.sh (via /etc/profile)
TRACE: ~/.profile
```

**Paso 5.** Ahora iniciá un shell interactivo **sin login**:

```bash
bash -i -c 'true'
```

```text
TRACE: ~/.bashrc
```

**Paso 6.** Y un shell no interactivo simple, y luego el mismo con `BASH_ENV` establecido:

```bash
bash -c 'true'
echo "---"
printf 'echo "TRACE: $BASH_ENV" >&2\n' > ~/lab-105.1/env.sh
BASH_ENV=~/lab-105.1/env.sh bash -c 'true'
```

```text
---
TRACE: /home/student/lab-105.1/env.sh
```

**Paso 7.** Verificá el archivo interactivo a nivel de sistema. Su nombre depende de la distribución:

```bash
ls -l /etc/bash.bashrc /etc/bashrc 2>&1
grep -n 'bash\.bashrc\|/etc/bashrc' ~/.bashrc /etc/skel/.bashrc 2>/dev/null | head
```

```text
ls: cannot access '/etc/bashrc': No such file or directory
-rw-r--r-- 1 root root 2319 Mar 31 09:12 /etc/bash.bashrc
```

**Paso 8.** Comprobá que un shell de login **no** lee `~/.bashrc` por sí solo, y observá el puente convencional que trae cada distribución:

```bash
grep -n -A3 'bashrc' ~/.profile
```

```text
14:if [ -n "$BASH_VERSION" ]; then
15-    # include .bashrc if it exists
16-    if [ -f "$HOME/.bashrc" ]; then
17-        . "$HOME/.bashrc"
18-    fi
```

**Paso 9.** Restaurá `~/.bash_profile` y `~/.bash_login` para el próximo ejercicio:

```bash
mv ~/lab-105.1/.bash_profile ~/lab-105.1/.bash_login ~/ 2>/dev/null; ls -A ~/.bash*
```

> **Q2.1** — Escribí el orden exacto de búsqueda que Bash usa para el archivo de login por usuario, y decí qué pasa con los otros dos candidatos cuando el primero existe.
> **Q2.2** — En el Paso 3 el shell de login también era interactivo, y sin embargo `~/.bashrc` *no* fue rastreado. Explicá por qué, y explicá por qué de todos modos viste salida de `~/.bashrc` en una sesión de terminal real.
> **Q2.3** — Pusiste `export PATH="$HOME/bin:$PATH"` en `~/.bashrc`. Después de abrir una terminal y tipear `bash` dos veces, ¿cómo se ve `$PATH`, y qué archivo debería haber contenido esa línea?
> **Q2.4** — ¿Por qué `/etc/profile.d/00-lab-trace.sh` es un mejor lugar para un cambio a nivel de sistema que agregar al final de `/etc/profile`?
> **Q2.5** — `BASH_ENV` fue respetado en el Paso 6. Nombrá una consecuencia de seguridad de ese mecanismo para un contexto tipo setuid, y nombrá la variable equivalente en POSIX/`sh`.

---

## Ejercicio 3 — Variables de shell versus variables de entorno

`set`, `env`, `export` y `unset` son cuatro herramientas distintas que operan sobre dos espacios de nombres distintos. Confundirlas es la falla más común en este objetivo.

**Paso 1.** Creá una variable de shell común — notá que no hay espacios alrededor del `=`:

```bash
LAB_LOCAL="shell-only"
echo "value: $LAB_LOCAL"
```

```text
value: shell-only
```

**Paso 2.** Preguntale a cada herramienta si puede verla:

```bash
set   | grep '^LAB_LOCAL='   ; echo "set   -> $?"
env   | grep '^LAB_LOCAL='   ; echo "env   -> $?"
export -p | grep 'LAB_LOCAL' ; echo "export -> $?"
```

```text
LAB_LOCAL='shell-only'
set   -> 0
env   -> 1
export -> 1
```

**Paso 3.** Inspeccioná los atributos de la variable, y después comprobá si un proceso hijo la hereda:

```bash
declare -p LAB_LOCAL
bash -c 'echo "child sees: [$LAB_LOCAL]"'
```

```text
declare -- LAB_LOCAL="shell-only"
child sees: []
```

**Paso 4.** Promovela al entorno y repetí ambas comprobaciones:

```bash
export LAB_LOCAL
declare -p LAB_LOCAL
env | grep '^LAB_LOCAL='
bash -c 'echo "child sees: [$LAB_LOCAL]"'
```

```text
declare -x LAB_LOCAL="shell-only"
LAB_LOCAL=shell-only
child sees: [shell-only]
```

**Paso 5.** Degradala de nuevo *sin* destruirla, y después destruila:

```bash
export -n LAB_LOCAL
declare -p LAB_LOCAL
unset -v LAB_LOCAL
declare -p LAB_LOCAL
```

```text
declare -- LAB_LOCAL="shell-only"
bash: declare: LAB_LOCAL: not found
```

**Paso 6.** Establecé una variable para exactamente un comando — un prefijo de asignación temporal no toca el shell actual:

```bash
LAB_ONCE=yes env | grep '^LAB_ONCE='
echo "after: [${LAB_ONCE:-unset}]"
```

```text
LAB_ONCE=yes
after: [unset]
```

**Paso 7.** Usá `env` para *quitar* una variable del entorno de un hijo y para construir un entorno prístino:

```bash
export LAB_KEEP=1 LAB_DROP=1
env -u LAB_DROP bash -c 'echo "keep=[$LAB_KEEP] drop=[$LAB_DROP]"'
env -i bash --noprofile --norc -c 'echo "count: $(env | wc -l)"; env'
```

```text
keep=[1] drop=[]
count: 3
PWD=/home/student
SHLVL=1
_=/usr/bin/env
```

**Paso 8.** Contrastá los dos comandos que "listan todo". `set` sin argumentos imprime variables de shell *y definiciones de funciones*; el modo POSIX lo restringe a variables:

```bash
set | wc -l
( set -o posix; set | wc -l )
env | wc -l
```

```text
312
118
41
```

**Paso 9.** Demostrá un atributo que resiste a `unset`:

```bash
declare -r LAB_RO="cannot change"
LAB_RO="try"
unset -v LAB_RO
echo "still: $LAB_RO"
```

```text
bash: LAB_RO: readonly variable
bash: unset: LAB_RO: cannot unset: readonly variable
still: cannot change
```

**Paso 10.** Limpiá (la variable de solo lectura va a desaparecer solamente cuando este shell termine):

```bash
unset -v LAB_KEEP LAB_DROP
```

> **Q3.1** — En una oración cada uno, decí qué muestran `set`, `env`, `export -p` y `declare -p` que los otros no muestran.
> **Q3.2** — `export -n VAR` y `unset -v VAR` ambos dejan vacío a `env | grep VAR`. ¿Cuál es la diferencia observable en el shell actual?
> **Q3.3** — ¿Es `env` un builtin del shell? Probá tu respuesta con un comando, y explicá por qué `LAB_ONCE=yes env` funciona mientras que `LAB_ONCE=yes echo $LAB_ONCE` no imprime nada.
> **Q3.4** — ¿Por qué `set -o posix` reduce tan drásticamente la salida de `set`?
> **Q3.5** — Un colega reporta "la exporté pero el script sigue sin verla". Dá las dos causas más probables según lo que observaste en los Pasos 3–5.

---

## Ejercicio 4 — La ruta de búsqueda de comandos y la tabla hash

**Paso 1.** Imprimí `PATH` con una entrada por línea — los dos puntos son separadores de campo, y el orden de los campos es el orden de búsqueda:

```bash
echo "$PATH" | tr ':' '\n' | nl
```

```text
     1  /home/student/.local/bin
     2  /usr/local/sbin
     3  /usr/local/bin
     4  /usr/sbin
     5  /usr/bin
     6  /sbin
     7  /bin
```

**Paso 2.** Construí un comando privado y observá que todavía no se puede encontrar:

```bash
mkdir -p ~/bin
cat > ~/bin/lab-tool <<'EOF'
#!/bin/bash
echo "lab-tool v1 from $0"
EOF
chmod 0755 ~/bin/lab-tool
lab-tool
```

```text
bash: lab-tool: command not found
```

**Paso 3.** Antepuesto el directorio y resolvé el comando de tres maneras:

```bash
PATH="$HOME/bin:$PATH"
lab-tool
type lab-tool
type -a lab-tool
command -v lab-tool
type -t lab-tool
```

```text
lab-tool v1 from /home/student/bin/lab-tool
lab-tool is /home/student/bin/lab-tool
lab-tool is /home/student/bin/lab-tool
/home/student/bin/lab-tool
file
```

**Paso 4.** Ahora exponé la tabla hash. Bash cachea las rutas completas de los comandos ejecutados para no reescanear `PATH` cada vez:

```bash
hash
```

```text
hits	command
   1	/home/student/bin/lab-tool
   3	/usr/bin/ls
```

**Paso 5.** Creá un duplicado de *mayor prioridad* y observá cómo la caché sirve datos obsoletos:

```bash
sudo install -m 0755 /dev/stdin /usr/local/bin/lab-tool <<'EOF'
#!/bin/bash
echo "lab-tool v2 from $0"
EOF
PATH="/usr/local/bin:$HOME/bin:${PATH#$HOME/bin:}"
lab-tool
type -a lab-tool
```

```text
lab-tool v1 from /home/student/bin/lab-tool
lab-tool is /usr/local/bin/lab-tool
lab-tool is /home/student/bin/lab-tool
```

**Paso 6.** Notá la contradicción — `type -a` (que reescanea) y la ejecución real no coinciden. Vaciá la caché:

```bash
hash -d lab-tool     # forget one entry
lab-tool
hash -r              # forget everything
```

```text
lab-tool v2 from /usr/local/bin/lab-tool
```

**Paso 7.** Examiná la sintaxis peligrosa de `PATH`. Un campo vacío — dos puntos al inicio, al final, o `::` — significa *el directorio actual*:

```bash
mkdir -p ~/lab-105.1/trap && cd ~/lab-105.1/trap
cat > ls <<'EOF'
#!/bin/bash
echo "*** this is not coreutils ls ***"
EOF
chmod 0755 ls
PATH="$PATH:" ; hash -r
ls
```

```text
*** this is not coreutils ls ***
```

**Paso 8.** Reparalo y verificá:

```bash
PATH="${PATH%:}" ; hash -r
ls
cd ~
```

```text
ls
```

**Paso 9.** Hacé que un cambio de `PATH` sea duradero e idempotente. Poné esto en `~/.profile` (shell de login), no en `~/.bashrc`:

```bash
cat >> ~/.profile <<'EOF'

# LAB 105.1 — idempotent PATH extension
case ":${PATH}:" in
    *:"$HOME/bin":*) ;;
    *) PATH="$HOME/bin:$PATH" ;;
esac
export PATH
EOF
bash -l -i -c 'echo "$PATH" | tr ":" "\n" | grep -c "^$HOME/bin$"'
```

```text
1
```

**Paso 10.** Confirmá que el anidamiento ya no duplica la entrada:

```bash
bash -l -i -c 'bash -i -c "bash -i -c \"echo SHLVL=\\\$SHLVL; echo \\\$PATH | tr : \\\\n | grep -c bin\\$\""'
```

> **Q4.1** — Dado `PATH=/usr/local/bin:/usr/bin:/bin`, un archivo `/usr/bin/foo` (modo 0755) y `/usr/local/bin/foo` (modo 0644), ¿cuál se ejecuta cuando tipeás `foo`, y por qué?
> **Q4.2** — En el Paso 5, `type -a` reportó `/usr/local/bin/lab-tool` primero, pero se ejecutó `/home/student/bin/lab-tool`. Explicá el mecanismo y dá dos comandos que lo arreglen.
> **Q4.3** — Nombrá las tres formas de escribir `PATH` que incluyen silenciosamente el directorio de trabajo actual, y explicá el ataque que habilitan en un `/tmp` compartido.
> **Q4.4** — ¿Por qué `which lab-tool` a veces no coincide con `type lab-tool`? ¿Cuál de los dos es autoritativo respecto de lo que Bash va a ejecutar realmente?
> **Q4.5** — ¿Por qué `~/.profile` es el hogar correcto para una asignación de `PATH` mientras que `~/.bashrc` es el hogar correcto para un `alias`?

---

## Ejercicio 5 — Alias: reglas de expansión y sus límites

**Paso 1.** Listá lo que tu distribución ya definió, y después creá los tuyos:

```bash
alias
alias ll='ls -alF --color=auto'
alias vi='vim'
alias
```

```text
alias ls='ls --color=auto'
alias ls='ls --color=auto'
alias ll='ls -alF --color=auto'
alias vi='vim'
```

**Paso 2.** Resolvé un nombre con alias y observá la precedencia:

```bash
type -a ls
type -t ls
```

```text
ls is aliased to `ls --color=auto'
ls is /usr/bin/ls
alias
```

**Paso 3.** Evitá el alias sin eliminarlo — tres técnicas independientes:

```bash
\ls -d /etc | cat        # quoting any character suppresses alias lookup
'ls' -d /etc | cat
command ls -d /etc | cat
```

```text
/etc
/etc
/etc
```

**Paso 4.** Comprobá que los alias son una característica *solo interactiva* por defecto:

```bash
cat > ~/lab-105.1/alias-test.sh <<'EOF'
#!/bin/bash
alias hello='echo "hello from alias"'
hello
EOF
chmod 0755 ~/lab-105.1/alias-test.sh
~/lab-105.1/alias-test.sh
```

```text
/home/student/lab-105.1/alias-test.sh: line 3: hello: command not found
```

**Paso 5.** Habilitalos explícitamente y volvé a ejecutar:

```bash
sed -i '2i shopt -s expand_aliases' ~/lab-105.1/alias-test.sh
~/lab-105.1/alias-test.sh
```

```text
hello from alias
```

**Paso 6.** Descubrí la regla del momento del parseo. Los alias se expanden cuando una línea se *lee*, no cuando se *ejecuta*:

```bash
bash -c 'shopt -s expand_aliases; alias hi="echo HI"; hi'
echo "---"
bash -c 'shopt -s expand_aliases
alias hi="echo HI"
hi'
```

```text
bash: line 1: hi: command not found
---
HI
```

**Paso 7.** Usá la regla del espacio final, que es la única razón por la que `sudo ll` puede llegar a funcionar:

```bash
alias please='sudo '        # note the trailing space
alias ll='ls -alF'
please ll /root | head -3
```

```text
total 32
drwx------.  5 root root 4096 Aug 20 11:02 ./
dr-xr-xr-x. 19 root root 4096 Aug  1 08:44 ../
```

**Paso 8.** Descubrí el límite duro — un alias no puede procesar argumentos posicionalmente:

```bash
alias greet='echo "Hello, $1!"'
greet World
```

```text
Hello, ! World
```

**Paso 9.** Eliminalos:

```bash
unalias please greet vi
unalias -a          # removes ALL aliases in this shell
alias | wc -l
```

```text
0
```

> **Q5.1** — Ordená estos de mayor a menor precedencia cuando Bash resuelve una palabra de comando: archivo externo en `PATH`, función de shell, alias, builtin, palabra reservada.
> **Q5.2** — ¿Por qué `greet World` en el Paso 8 imprimió `Hello, ! World` en lugar de `Hello, World!`? ¿Cuál es la construcción correcta para este trabajo?
> **Q5.3** — En el Paso 6, la versión de una línea falló pero la de tres líneas funcionó. Enunciá la regla que explica esto, y decí por qué también implica que un alias definido *dentro* del cuerpo de una función es inutilizable en esa misma función.
> **Q5.4** — Dá dos maneras de ejecutar el `/usr/bin/ls` real mientras `alias ls='ls --color=auto'` está activo, y explicá por qué `alias ls='ls --color=auto'` no causa recursión infinita.
> **Q5.5** — ¿Qué cambia mecánicamente el espacio final en `alias please='sudo '`?

---

## Ejercicio 6 — Funciones de Bash para secuencias de comandos usadas con frecuencia

**Paso 1.** Escribí una función usando ambas sintaxis aceptadas y comparalas:

```bash
lab_posix() { echo "POSIX form, args: $#"; }
function lab_keyword { echo "keyword form, args: $#"; }
lab_posix a b
lab_keyword a b c
type -t lab_posix
```

```text
POSIX form, args: 2
keyword form, args: 3
function
```

**Paso 2.** Construí una función de calidad productiva: ámbito local, validación de argumentos, un estado de salida explícito, y sin efectos secundarios sobre las variables de quien la llama:

```bash
mkcd() {
    local dir="$1"
    if [[ -z "$dir" ]]; then
        printf 'mkcd: usage: mkcd DIRECTORY\n' >&2
        return 2
    fi
    mkdir -p -- "$dir" && cd -P -- "$dir" || return 1
}
mkcd; echo "status=$?"
mkcd ~/lab-105.1/deep/nested; echo "status=$? pwd=$PWD"
echo "leaked dir variable: [${dir:-unset}]"
cd ~
```

```text
mkcd: usage: mkcd DIRECTORY
status=2
status=0 pwd=/home/student/lab-105.1/deep/nested
leaked dir variable: [unset]
```

**Paso 3.** Inspeccioná las funciones:

```bash
declare -F | head -3
declare -F mkcd
declare -f mkcd
```

```text
declare -f mkcd
mkcd
mkcd () 
{ 
    local dir="$1";
    if [[ -z "$dir" ]]; then
        printf 'mkcd: usage: mkcd DIRECTORY\n' 1>&2;
        return 2;
    fi;
    mkdir -p -- "$dir" && cd -P -- "$dir" || return 1
}
```

**Paso 4.** Mostrá que las funciones, igual que las variables comunes, **no** se heredan por defecto — y después exportá una:

```bash
bash -c 'type -t mkcd || echo "child: no such function"'
export -f mkcd
bash -c 'type -t mkcd'
```

```text
child: no such function
function
```

**Paso 5.** Mirá *cómo* se transporta la exportación. Viaja como una variable de entorno común con un nombre mutilado:

```bash
env | grep -A2 'BASH_FUNC'
```

```text
BASH_FUNC_mkcd%%=() {  local dir="$1";
 if [[ -z "$dir" ]]; then
     printf 'mkcd: usage: mkcd DIRECTORY\n' 1>&2;
```

**Paso 6.** Demostrá que una función tiene precedencia sobre un comando externo, y cómo llegar al original:

```bash
ls() { echo "function ls intercepted: $*"; command ls "$@"; }
ls /etc/hostname
type -a ls
unset -f ls
```

```text
function ls intercepted: /etc/hostname
/etc/hostname
ls is a function
ls () 
{ 
    echo "function ls intercepted: $*";
    command ls "$@"
}
ls is /usr/bin/ls
```

**Paso 7.** Hacé que las funciones sean persistentes de la manera mantenible — una biblioteca separada de la que se hace source desde `~/.bashrc`:

```bash
mkdir -p ~/.bash_functions.d
cat > ~/.bash_functions.d/mkcd.sh <<'EOF'
# mkcd DIRECTORY — create a directory tree and enter it.
mkcd() {
    local dir="$1"
    [[ -z "$dir" ]] && { printf 'mkcd: usage: mkcd DIRECTORY\n' >&2; return 2; }
    mkdir -p -- "$dir" && cd -P -- "$dir" || return 1
}
EOF
cat >> ~/.bashrc <<'EOF'

# LAB 105.1 — load personal function library
if [ -d "$HOME/.bash_functions.d" ]; then
    for _f in "$HOME/.bash_functions.d"/*.sh; do
        [ -r "$_f" ] && . "$_f"
    done
    unset -v _f
fi
EOF
bash -i -c 'type -t mkcd' 2>/dev/null
```

```text
function
```

**Paso 8.** Quitá la copia exportada para que deje de contaminar todos los procesos hijos:

```bash
export -fn mkcd
bash -c 'type -t mkcd || echo "child: clean"'
unset -f mkcd
```

```text
child: clean
```

> **Q6.1** — Dá tres capacidades que tiene una función y un alias no.
> **Q6.2** — ¿Qué hace realmente `local`, y qué se rompe en el Paso 2 si lo quitás? (Considerá a quien llama a la función y ya usa una variable llamada `dir`.)
> **Q6.3** — Dentro de una función, ¿cuándo deberías usar `return` y cuándo `exit`? ¿Qué pasa si un archivo del que se hizo *source* llama a `exit 1`?
> **Q6.4** — Explicá el nombre `BASH_FUNC_mkcd%%` visto en el Paso 5, incluyendo por qué la codificación no es simplemente `mkcd`.
> **Q6.5** — `unset mkcd` (sin flag) con una variable `mkcd` y una función `mkcd` ambas definidas: ¿cuál se elimina? ¿Qué flags hacen explícita la intención?

---

## Ejercicio 7 — Listas, agrupamiento, subshells, y `source` versus ejecutar

El objetivo de LPI lista *lists* como término: estos son los operadores que unen comandos en una sola unidad lógica.

**Paso 1.** Compará los cuatro separadores de listas. `;` es incondicional, `&&` y `||` son condicionales, `&` es asincrónico:

```bash
true ; echo "A: always runs"
true && echo "B: runs only after success"
false && echo "C: never printed"
false || echo "D: runs only after failure"
( sleep 0.2; echo "E: background finished" ) & echo "F: foreground continues"
wait
```

```text
A: always runs
B: runs only after success
D: runs only after failure
F: foreground continues
E: background finished
```

**Paso 2.** Leé el estado de salida del último comando — el valor que impulsa toda lista condicional:

```bash
grep -q root /etc/passwd ; echo "found  -> $?"
grep -q zzzz /etc/passwd ; echo "absent -> $?"
```

```text
found  -> 0
absent -> 1
```

**Paso 3.** Exponé la trampa clásica de precedencia de `&&`/`||`. Estos operadores tienen precedencia *igual* y asocian de izquierda a derecha, así que esto no es un if/else:

```bash
true && echo "then-branch" || echo "else-branch"
echo "--- now make the then-branch fail ---"
true && { echo "then-branch"; false; } || echo "else-branch"
```

```text
then-branch
--- now make the then-branch fail ---
then-branch
else-branch
```

**Paso 4.** Contrastá las dos construcciones de agrupamiento. `( )` bifurca un subshell; `{ }` corre en el shell actual:

```bash
LAB_G="original"
( LAB_G="changed in subshell"; cd /tmp; echo "inside (): $LAB_G  pwd=$PWD" )
echo "after (): $LAB_G  pwd=$PWD"
{ LAB_G="changed in group"; cd /tmp; echo "inside {}: $LAB_G  pwd=$PWD"; }
echo "after {}: $LAB_G  pwd=$PWD"
cd ~
```

```text
inside (): changed in subshell  pwd=/tmp
after (): original  pwd=/home/student
inside {}: changed in group  pwd=/tmp
after {}: changed in group  pwd=/tmp
```

**Paso 5.** Contá los niveles de anidamiento del shell para confirmar qué se bifurcó:

```bash
echo "SHLVL=$SHLVL BASH_SUBSHELL=$BASH_SUBSHELL BASHPID=$BASHPID PID=$$"
( echo "SHLVL=$SHLVL BASH_SUBSHELL=$BASH_SUBSHELL BASHPID=$BASHPID PID=$$" )
bash -c 'echo "SHLVL=$SHLVL"'
```

```text
SHLVL=1 BASH_SUBSHELL=0 BASHPID=4412 PID=4412
SHLVL=1 BASH_SUBSHELL=1 BASHPID=5033 PID=4412
SHLVL=2
```

**Paso 6.** Ahora la diferencia que el objetivo realmente evalúa. Escribí un script que establece una variable:

```bash
cat > ~/lab-105.1/setvar.sh <<'EOF'
LAB_FROM_FILE="set by the file"
echo "inside the file: pid=$BASHPID LAB_FROM_FILE=$LAB_FROM_FILE"
EOF
chmod 0755 ~/lab-105.1/setvar.sh
```

**Paso 7.** Ejecutalo, después hacé source de él, y compará el efecto sobre el shell *actual*:

```bash
unset -v LAB_FROM_FILE
~/lab-105.1/setvar.sh
echo "after execute: [${LAB_FROM_FILE:-unset}]  my pid=$BASHPID"
echo "---"
source ~/lab-105.1/setvar.sh
echo "after source : [${LAB_FROM_FILE:-unset}]  my pid=$BASHPID"
```

```text
inside the file: pid=5104 LAB_FROM_FILE=set by the file
after execute: [unset]  my pid=4412
---
inside the file: pid=4412 LAB_FROM_FILE=set by the file
after source : [set by the file]  my pid=4412
```

**Paso 8.** Confirmá que `.` y `source` son el mismo builtin, y que `.` busca en `PATH` cuando el argumento no contiene barras:

```bash
type . source
unset -v LAB_FROM_FILE
PATH="$HOME/lab-105.1:$PATH" . setvar.sh
echo "sourced via PATH: [$LAB_FROM_FILE]"
```

```text
. is a shell builtin
source is a shell builtin
inside the file: pid=4412 LAB_FROM_FILE=set by the file
sourced via PATH: [set by the file]
```

**Paso 9.** Pasá parámetros posicionales a un archivo del que se hace source — una extensión de Bash que vale la pena conocer:

```bash
set -- outer1 outer2
cat > ~/lab-105.1/args.sh <<'EOF'
echo "sourced file sees \$1=$1 \$#=$#"
EOF
source ~/lab-105.1/args.sh inner1 inner2 inner3
echo "caller still sees \$1=$1 \$#=$#"
set --
```

```text
sourced file sees $1=inner1 $#=3
caller still sees $1=outer1 $#=2
```

> **Q7.1** — Escribí la salida de `false && echo A || echo B ; echo C` y justificá cada línea.
> **Q7.2** — ¿Por qué `cd /var/log && ./cleanup.sh` es materialmente más seguro que `cd /var/log ; ./cleanup.sh`?
> **Q7.3** — Un script termina con `( cd /opt/app && ./build.sh )`. El autor afirma que los paréntesis son "solo por legibilidad". ¿Qué garantizan realmente?
> **Q7.4** — Tu `~/.bashrc` establece `EDITOR=vim`, pero un script de shell que ejecutás no lo ve. Explicá el mecanismo y dá dos maneras de arreglarlo.
> **Q7.5** — `source ~/.bashrc` y `bash` se ofrecen ambos como "recargar mi configuración". Comparalos en términos de cantidad de procesos, `SHLVL`, y configuraciones eliminadas (por ejemplo, un alias que acabás de borrar del archivo).

---

## Ejercicio 8 — Prompts: `PS1`, `PROMPT_COMMAND`, `PS2`, `PS4`

**Paso 1.** Inspeccioná el prompt primario actual. Entrecomillalo para que sobrevivan los escapes:

```bash
echo "$PS1"
```

```text
\[\e]0;\u@\h: \w\a\]${debian_chroot:+($debian_chroot)}\[\033[01;32m\]\u@\h\[\033[00m\]:\[\033[01;34m\]\w\[\033[00m\]\$ 
```

**Paso 2.** Guardalo y construí uno desde cero, escape por escape:

```bash
LAB_PS1_ORIG="$PS1"
PS1='\u@\h:\w\$ '        ; : "user@host:cwd$"
PS1='[\t] \u@\H \W\$ '   ; : "timestamp, FQDN, basename of cwd"
PS1='\!:\# \$ '          ; : "history number : command number"
```

**Paso 3.** Agregá color — y observá por qué `\[` y `\]` son obligatorios. Primero la versión **incorrecta**:

```bash
PS1='\033[01;31m\u@\h\033[00m:\w\$ '
```

Ahora tipeá un comando más largo que el ancho de tu terminal, después presioná `Ctrl-a` / `Ctrl-e` y mirá cómo el cursor aterriza en la columna equivocada o sobrescribe el prompt. Después la versión **correcta**:

```bash
PS1='\[\033[01;31m\]\u@\h\[\033[00m\]:\w\$ '
```

**Paso 4.** Mostrá el último estado de salida en el prompt vía `PROMPT_COMMAND`, que se ejecuta inmediatamente antes de que se imprima `PS1`:

```bash
lab_prompt() {
    local rc=$?                          # MUST be the first statement
    if (( rc == 0 )); then LAB_RC="\[\033[32m\]ok\[\033[0m\]"
    else                   LAB_RC="\[\033[31m\]$rc\[\033[0m\]"; fi
}
PROMPT_COMMAND=lab_prompt
PS1='${LAB_RC} \w\$ '
true
false
grep -q x /nonexistent-file-105 2>/dev/null
```

```text
ok ~$ true
ok ~$ false
1 ~$ grep -q x /nonexistent-file-105 2>/dev/null
2 ~$
```

**Paso 5.** Cambiá el prompt de continuación y disparalo con una comilla sin cerrar:

```bash
PS2='...continued> '
echo "line one
line two"
```

```text
...continued> line one
line two
```

**Paso 6.** Convertí `PS4` en un instrumento de depuración real. El valor por defecto es `+ `, que no te dice nada sobre *dónde* estás:

```bash
cat > ~/lab-105.1/trace-demo.sh <<'EOF'
#!/bin/bash
step_one() { local n=1; echo "in step_one"; }
step_two() { step_one; echo "in step_two"; }
step_two
EOF
chmod 0755 ~/lab-105.1/trace-demo.sh
bash -x ~/lab-105.1/trace-demo.sh 2>&1 | head -6
echo "=== with a useful PS4 ==="
PS4='+ ${BASH_SOURCE##*/}:${LINENO}:${FUNCNAME[0]:-main}: ' bash -x ~/lab-105.1/trace-demo.sh 2>&1 | head -6
```

```text
+ step_two
+ step_one
+ local n=1
+ echo 'in step_one'
in step_one
+ echo 'in step_two'
=== with a useful PS4 ===
+ trace-demo.sh:4:main: step_two
+ trace-demo.sh:3:step_two: step_one
+ trace-demo.sh:2:step_one: local n=1
+ trace-demo.sh:2:step_one: echo 'in step_one'
in step_one
+ trace-demo.sh:3:step_two: echo 'in step_two'
```

**Paso 7.** Activá y desactivá el rastreo alrededor de una región sospechosa de una sesión interactiva:

```bash
set -x
LAB_X=$(date +%Y)
set +x
```

```text
++ date +%Y
+ LAB_X=2026
+ set +x
```

**Paso 8.** Ajustá el comportamiento interactivo relacionado con `shopt` y las variables de historial — estas van en `~/.bashrc`, nunca en `~/.profile`:

```bash
shopt -s checkwinsize histappend cmdhist
HISTCONTROL=ignoreboth
HISTSIZE=10000
HISTFILESIZE=20000
shopt | grep -E 'checkwinsize|histappend'
```

```text
checkwinsize   	on
histappend     	on
```

**Paso 9.** Restaurá el prompt original:

```bash
PS1="$LAB_PS1_ORIG"; unset -v PROMPT_COMMAND LAB_RC; unset -f lab_prompt; PS2='> '
```

> **Q8.1** — ¿Cuál es la diferencia funcional entre `\w` y `\W`, y entre `\h` y `\H`?
> **Q8.2** — Explicá con precisión qué hacen `\[` y `\]` y qué síntoma visible aparece cuando se omiten alrededor de un escape de color.
> **Q8.3** — En `lab_prompt`, ¿por qué `local rc=$?` tiene que ser la primerísima instrucción de la función?
> **Q8.4** — `PS1` tiene que ser una variable *de shell* para funcionar — ¿exportarla ayuda a que un Bash hijo herede tu prompt? Explicá qué pasa realmente.
> **Q8.5** — Nombrá la variable de prompt usada por cada uno de: un comando multilínea con salto de línea; la salida de `set -x`; el builtin `select`.

---

## Ejercicio 9 — Directorios esqueleto para cuentas nuevas

**Paso 1.** Inspeccioná el esqueleto. Los archivos ocultos son el punto central, así que `-A` es obligatorio:

```bash
ls -lA /etc/skel/
```

```text
total 20
-rw-r--r--. 1 root root  220 Mar 31 09:12 .bash_logout
-rw-r--r--. 1 root root 3771 Mar 31 09:12 .bashrc
-rw-r--r--. 1 root root  807 Mar 31 09:12 .profile
```

**Paso 2.** Confirmá qué directorio va a usar realmente `useradd` — no asumas `/etc/skel`:

```bash
useradd -D
grep -vE '^\s*(#|$)' /etc/default/useradd
grep -iE '^(CREATE_HOME|UMASK|HOME_MODE)' /etc/login.defs
```

```text
GROUP=100
HOME=/home
INACTIVE=-1
EXPIRE=
SHELL=/bin/bash
SKEL=/etc/skel
CREATE_MAIL_SPOOL=yes
CREATE_HOME	yes
UMASK		022
HOME_MODE	0700
```

**Paso 3.** Agregá un archivo estándar al esqueleto, y establecé su modo deliberadamente — `useradd` copia el modo, no aplica el umask de quien lo invoca:

```bash
sudo tee /etc/skel/.bash_aliases >/dev/null <<'EOF'
# Site-wide defaults, provisioned from /etc/skel
alias ll='ls -alF'
alias rm='rm -I --preserve-root'
EOF
sudo chmod 0644 /etc/skel/.bash_aliases
sudo mkdir -p /etc/skel/.ssh && sudo chmod 0700 /etc/skel/.ssh
ls -ldA /etc/skel/.bash_aliases /etc/skel/.ssh
```

```text
-rw-r--r--. 1 root root 92 Aug 26 10:31 /etc/skel/.bash_aliases
drwx------. 2 root root  6 Aug 26 10:31 /etc/skel/.ssh
```

**Paso 4.** Creá una cuenta y verificá la copia:

```bash
sudo useradd -m -s /bin/bash -c "Lab user 105.1" labdev
sudo ls -lA /home/labdev/
```

```text
total 24
-rw-r--r--. 1 labdev labdev   92 Aug 26 10:32 .bash_aliases
-rw-r--r--. 1 labdev labdev  220 Aug 26 10:32 .bash_logout
-rw-r--r--. 1 labdev labdev 3771 Aug 26 10:32 .bashrc
-rw-r--r--. 1 labdev labdev  807 Aug 26 10:32 .profile
drwx------. 2 labdev labdev    6 Aug 26 10:32 .ssh
```

**Paso 5.** Comprobá la propiedad y el modo del propio directorio home:

```bash
sudo stat -c '%n %U:%G %a' /home/labdev /home/labdev/.bash_aliases /home/labdev/.ssh
```

```text
/home/labdev labdev:labdev 700
/home/labdev/.bash_aliases labdev:labdev 644
/home/labdev/.ssh labdev:labdev 700
```

**Paso 6.** Comprobá que el esqueleto es una plantilla de *un solo disparo*. Cambialo, y después revisá una cuenta existente:

```bash
echo "alias lab-new='echo added AFTER labdev existed'" | sudo tee -a /etc/skel/.bash_aliases >/dev/null
sudo grep -c 'lab-new' /etc/skel/.bash_aliases /home/labdev/.bash_aliases
```

```text
/etc/skel/.bash_aliases:1
/home/labdev/.bash_aliases:0
```

**Paso 7.** Usá un esqueleto alternativo para una cuenta específica de un rol:

```bash
sudo mkdir -p /etc/skel-ops
sudo tee /etc/skel-ops/.bashrc >/dev/null <<'EOF'
export PATH="/opt/ops/bin:$PATH"
export EDITOR=vim
PS1='[OPS] \u@\h:\w\$ '
EOF
sudo useradd -m -k /etc/skel-ops -s /bin/bash labops
sudo ls -A /home/labops/
sudo head -1 /home/labops/.bashrc
```

```text
.bashrc
export PATH="/opt/ops/bin:$PATH"
```

**Paso 8.** Alcanzá también a los usuarios *existentes* — el mecanismo drop-in que `/etc/skel` no puede proveer:

```bash
sudo tee /etc/profile.d/zz-site-defaults.sh >/dev/null <<'EOF'
# Applies to every user, existing and future, at login.
export EDITOR="${EDITOR:-vim}"
export LESS="-R -F -X"
umask 027
EOF
sudo chmod 0644 /etc/profile.d/zz-site-defaults.sh
sudo -u labdev bash -l -c 'echo "EDITOR=$EDITOR umask=$(umask)"'
```

```text
EDITOR=vim umask=0027
```

**Paso 9.** Eliminá las cuentas de prueba, incluidos sus directorios home y sus spools de correo:

```bash
sudo userdel -r labdev 2>/dev/null
sudo userdel -r labops 2>/dev/null
sudo rm -f /etc/skel/.bash_aliases
sudo rmdir /etc/skel/.ssh
sudo rm -rf /etc/skel-ops
sudo rm -f /etc/profile.d/zz-site-defaults.sh
getent passwd labdev labops ; echo "remaining: $?"
```

```text
remaining: 2
```

> **Q9.1** — ¿Qué opción de `useradd` dispara la copia del esqueleto, y qué pasa si la omitís en un sistema donde `CREATE_HOME` es `no`?
> **Q9.2** — Editaste `/etc/skel/.bashrc` para arreglar un bug de `PATH` para 300 usuarios existentes. ¿Funcionó? ¿Cuál es el mecanismo correcto?
> **Q9.3** — Los archivos aterrizan en `/home/labdev` con propiedad de `labdev` aunque los copió `root`. ¿Qué propiedad y qué bits de permisos se preservan de `/etc/skel`, y cuáles no?
> **Q9.4** — Dá la opción y la clave de configuración que te permiten usar `/etc/skel-ops` en lugar de `/etc/skel`, una para una invocación única y otra como valor por defecto del sistema.
> **Q9.5** — ¿Por qué `/etc/skel/.ssh` debería tener modo `0700`, y qué pasa con OpenSSH si un `authorized_keys` copiado termina con permiso de escritura para el grupo?

---

## Ejercicio 10 — `~/.bash_logout`, trampas no interactivas, y restauración

**Paso 1.** Confirmá cuándo se ejecuta el archivo de logout. Es un hook *exclusivo de shells de login*:

```bash
cat > ~/.bash_logout <<'EOF'
echo "TRACE: ~/.bash_logout ran (pid $$)" >&2
EOF
echo "--- login shell ---"
bash -l -i -c 'true'
echo "--- non-login shell ---"
bash -i -c 'true'
```

```text
--- login shell ---
TRACE: ~/.bash_logout ran (pid 5411)
--- non-login shell ---
```

**Paso 2.** Mirá qué ponen realmente las distribuciones ahí — limpiar la consola para que el próximo usuario no pueda hacer scroll hacia atrás:

```bash
cat /etc/skel/.bash_logout
```

```text
# ~/.bash_logout: executed by bash(1) when login shell exits.

# when leaving the console clear the screen to increase privacy
if [ "$SHELL" = "/bin/bash" ]; then
    [ -x /usr/bin/clear_console ] && /usr/bin/clear_console -q
fi
```

**Paso 3.** Reproducí la ruptura de producción más común en este objetivo. Bash hace source de `~/.bashrc` cuando detecta que stdin es una conexión de red — incluso para un comando remoto no interactivo:

```bash
cp ~/.bashrc ~/lab-105.1/bashrc.safe
sed -i '1i echo "Welcome to $(hostname)!"' ~/.bashrc
ssh localhost 'echo REMOTE-OK'
echo "--- now try a file transfer ---"
scp ~/lab-105.1/bashrc.safe localhost:/tmp/ 2>&1 | tail -3
```

```text
Welcome to lab01!
REMOTE-OK
--- now try a file transfer ---
Welcome to lab01!
bash: line 1: Received message too long 1114795883
```

**Paso 4.** Aplicá la protección estándar — la razón por la que todo `~/.bashrc` distribuido empieza con ella:

```bash
sed -i '1i case $- in *i*) ;; *) return;; esac' ~/.bashrc
head -2 ~/.bashrc
scp ~/lab-105.1/bashrc.safe localhost:/tmp/ 2>&1 | tail -2
```

```text
case $- in *i*) ;; *) return;; esac
echo "Welcome to lab01!"
bashrc.safe    100% 3771     4.1MB/s   00:00
```

**Paso 5.** Examiná el entorno a nivel de PAM, que no es ni un script de shell ni responsabilidad de Bash:

```bash
cat /etc/environment
grep -n 'pam_env' /etc/pam.d/login /etc/pam.d/sshd 2>/dev/null | head -4
```

```text
PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
/etc/pam.d/login:12:session       required     pam_env.so readenv=1
/etc/pam.d/sshd:9:session         required     pam_env.so
```

**Paso 6.** Comprobá que no es sintaxis de shell:

```bash
echo 'LAB_PAM=hello' | sudo tee -a /etc/environment >/dev/null
echo 'LAB_BAD=$HOME/x' | sudo tee -a /etc/environment >/dev/null
ssh localhost 'echo "LAB_PAM=[$LAB_PAM] LAB_BAD=[$LAB_BAD]"'
sudo sed -i '/^LAB_PAM=\|^LAB_BAD=/d' /etc/environment
```

```text
LAB_PAM=[hello] LAB_BAD=[$HOME/x]
```

**Paso 7.** Restauración completa — devolvé el sistema a su estado original:

```bash
# per-user files
cp -f ~/lab-105.1/backup/.bashrc      ~/.bashrc      2>/dev/null
cp -f ~/lab-105.1/backup/.profile     ~/.profile     2>/dev/null
cp -f ~/lab-105.1/backup/.bash_logout ~/.bash_logout 2>/dev/null
[ -f ~/lab-105.1/backup/.bash_profile ] || rm -f ~/.bash_profile
[ -f ~/lab-105.1/backup/.bash_login ]   || rm -f ~/.bash_login
rm -rf ~/.bash_functions.d ~/bin/lab-tool

# system files
sudo rm -f /etc/profile.d/00-lab-trace.sh /usr/local/bin/lab-tool

# verify nothing is left
bash -l -i -c 'true' 2>&1 | grep -c TRACE
grep -c 'LAB 105.1' ~/.bashrc ~/.profile
```

```text
0
0
0
```

**Paso 8.** Opcionalmente conservá el árbol del laboratorio para revisarlo, o eliminalo:

```bash
rm -rf ~/lab-105.1
```

> **Q10.1** — ¿Exactamente cuándo se ejecuta `~/.bash_logout`, y cuándo *no*? Nombrá una tarea que corresponda ahí y una que no.
> **Q10.2** — Explicá el mecanismo detrás de la falla de `scp` en el Paso 3. ¿Por qué producir salida en stdout rompe específicamente la transferencia?
> **Q10.3** — Decodificá `case $- in *i*) ;; *) return;; esac`. ¿Por qué `return` y no `exit`?
> **Q10.4** — Bash no lee `/etc/environment`. ¿Qué componente lo lee, y nombrá tres características del shell que no están disponibles en él?
> **Q10.5** — Un usuario reporta que el `PATH` establecido en `/etc/environment` es correcto por SSH pero falta en un trabajo de `cron`. Explicá el porqué, y dá el lugar correcto para esa configuración.

---

<details>
<summary><strong>Respuestas — hacé clic para expandir</strong></summary>

### Ejercicio 1 — Clasificar el shell

**A1.1** — La letra `i`. `$-` reporta los *flags de opciones* con los que el shell fue iniciado o que fueron cambiados por `set`; el estado de login no es un flag de opción sino una propiedad registrada al iniciar (si `argv[0]` empezaba con `-` o si se pasó `-l`/`--login`). Bash lo expone a través de la opción de shell de solo lectura `login_shell`, consultada con `shopt -q login_shell`.

**A1.2** — `su student` inicia un shell interactivo **sin login**, así que lee solamente `~/.bashrc` (más `/etc/bash.bashrc` donde la distribución lo soporte) y conserva la mayor parte del entorno del usuario que lo invoca. `su - student` (equivalente a `su -l`) inicia un shell **de login**: lee `/etc/profile`, después `/etc/profile.d/*.sh`, y después el primero de `~/.bash_profile` → `~/.bash_login` → `~/.profile`, y reinicia el entorno. `PATH` normalmente se establece en `/etc/profile` y `~/.profile`, y por eso solo la forma con `-` le da al usuario destino el `PATH` correcto — el síntoma clásico es que las utilidades de `sbin` "no se encuentran" después de `su root`.

**A1.3** — Formalmente: un shell no interactivo y sin login lee solamente el archivo nombrado por `$BASH_ENV`, si esa variable está establecida (el valor se expande y se usa directamente como nombre de archivo; *no* se busca en `PATH`). Sin embargo, Bash también detecta cuándo su entrada estándar está conectada a un socket de red — como cuando lo ejecuta `sshd` para un comando remoto — y en ese caso lee `~/.bashrc`. Ambas respuestas son correctas; la segunda es la que causa caídas reales (ver Ejercicio 10).

**A1.4** — `ps` muestra `argv[0]`, que es solo una *convención*: el programa de login antepone `-` para señalar "shell de login". Cualquier proceso puede poner en `argv[0]` lo que quiera, `bash --login` no produce un guion inicial, y un shell puede ser de login sin el guion. `shopt -q login_shell` le pregunta al shell mismo por su estado registrado, que es lo autoritativo.

---

### Ejercicio 2 — Orden de los archivos de inicio

**A2.1** — Para un **shell de login interactivo**, después de `/etc/profile`, Bash lee el primer archivo que exista y sea legible de entre:
1. `~/.bash_profile`
2. `~/.bash_login`
3. `~/.profile`

Los candidatos restantes **no se leen en absoluto**. Por eso agregar un `~/.bash_profile` en un sistema Debian desactiva silenciosamente `~/.profile` — una caída autoinfligida muy común.

**A2.2** — Un shell de login no hace source de `~/.bashrc`; las dos cadenas son independientes por diseño (`~/.profile` = "una vez por sesión, entorno"; `~/.bashrc` = "cada shell interactivo, comportamiento interactivo"). Ves salida de `~/.bashrc` en una terminal real por una de dos razones: o bien tu emulador de terminal abre un shell interactivo *sin login* (así que `~/.bashrc` es el único archivo que se lee), o bien tu `~/.profile` contiene el puente convencional `[ -f "$HOME/.bashrc" ] && . "$HOME/.bashrc"` visto en el Paso 8.

**A2.3** — `~/.bashrc` se ejecuta para *cada* shell interactivo, así que cada `bash` anidado antepone de nuevo:

```text
/home/student/bin:/home/student/bin:/home/student/bin:/usr/local/bin:/usr/bin:...
```

El hogar correcto es `~/.profile` (o `~/.bash_profile`), que se ejecuta una vez por sesión de login; `PATH` se exporta y por lo tanto es heredado por todo shell hijo. Si tiene que vivir en `~/.bashrc`, protegelo con el patrón idempotente `case ":${PATH}:" in *:"$HOME/bin":*) ;; *) ... ;; esac` del Ejercicio 4.

**A2.4** — `/etc/profile` es un archivo que pertenece a un paquete: una actualización de la distribución puede reemplazarlo, descartando silenciosamente tu cambio, o dejar un conflicto `.rpmnew`/`.dpkg-dist` para que un administrador lo resuelva. `/etc/profile.d/*.sh` es el punto de extensión soportado — los archivos ahí son sourceados por `/etc/profile` (y por `/etc/bashrc` para shells interactivos sin login en sistemas de la familia Red Hat), sobreviven a las actualizaciones, pueden agregarse y quitarse atómicamente por gestión de configuración, y son individualmente atribuibles a un paquete o a una política del sitio.

**A2.5** — Cualquier proceso que pueda establecer `BASH_ENV` en el entorno de un programa que después ejecute un script `bash` no interactivo logra ejecución de código arbitrario con los privilegios de ese script. Por eso `BASH_ENV` (y `ENV`, y `SHELLOPTS`) se ignoran cuando Bash detecta que está corriendo setuid/setgid sin `-p`, y por eso sanear el entorno importa para cualquier cosa privilegiada. El equivalente POSIX/`sh` para shells **interactivos** es `ENV`; Bash lo usa en lugar de `BASH_ENV` cuando se invoca como `sh` o en modo POSIX.

---

### Ejercicio 3 — Variables de shell versus de entorno

**A3.1**
- `set` (sin argumentos): cada **variable de shell** — exportada o no — *y* cada definición de función. Es el único que muestra las variables no exportadas junto con las funciones.
- `env`: el **entorno** que realmente se pasa a los procesos hijos (un comando externo de coreutils, así que solo puede ver lo que heredó). También modifica ese entorno para un comando.
- `export -p`: las variables exportadas *como sentencias `export`*, es decir, entrada reutilizable para el shell, desde el punto de vista del propio shell (incluye los atributos de solo lectura/exportado).
- `declare -p NAME`: una variable con sus **atributos** y tipo — `--` común, `-x` exportada, `-r` de solo lectura, `-i` entero, `-a` arreglo indexado, `-A` arreglo asociativo.

**A3.2** — `export -n VAR` quita solamente el atributo de exportación: la variable sigue existiendo en el shell actual con su valor (`declare -p` imprime `declare -- VAR="…"`, `echo $VAR` sigue funcionando), simplemente deja de heredarse. `unset -v VAR` la destruye por completo: `declare -p` reporta "not found" y `${VAR:-unset}` se expande al valor por defecto.

**A3.3** — No: `type env` reporta `env is /usr/bin/env`, un binario externo de coreutils. `LAB_ONCE=yes env` funciona porque el prefijo de asignación modifica el entorno del comando que se ejecuta, y `env` es un proceso separado que imprime el entorno que heredó. `LAB_ONCE=yes echo $LAB_ONCE` no imprime nada porque `$LAB_ONCE` es expandida por el shell **actual** *antes* de que la asignación tenga efecto y antes de que `echo` se ejecute — y `echo` es un builtin, así que tampoco hay un proceso nuevo que herede nada.

**A3.4** — Sin el modo POSIX, `set` imprime las variables de shell *y* el texto fuente completo de cada función definida. Una sesión Bash interactiva por defecto en la mayoría de las distribuciones lleva decenas de funciones (bash-completion por sí solo define cientos de líneas). `set -o posix` hace que `set` se ajuste a POSIX, imprimiendo solamente asignaciones de variables — que es la razón por la que `( set -o posix; set )` es la forma idiomática de volcar variables de manera limpia.

**A3.5** — (1) La variable fue exportada en un shell pero el script corre en una sesión *diferente* o fue iniciado antes de la exportación — las exportaciones se propagan solo hacia abajo, a los hijos creados después de la exportación, nunca hacia arriba ni lateralmente. (2) La exportación vive en `~/.bashrc`, y el script corre en un shell no interactivo que nunca lee `~/.bashrc` (Ejercicio 2). Una tercera causa frecuente: la asignación se escribió como `export VAR = value` con espacios, que Bash interpreta como ejecutar el comando `export` con tres argumentos.

---

### Ejercicio 4 — `PATH` y la tabla hash

**A4.1** — Se ejecuta `/usr/bin/foo`. Bash recorre `PATH` de izquierda a derecha y selecciona la primera entrada que sea un **archivo regular con permiso de ejecución** para el usuario que llama. `/usr/local/bin/foo` se encuentra primero pero no es ejecutable (0644), así que la búsqueda continúa. Notá el modo de falla: si `/usr/local/bin/foo` hubiera tenido modo 0755 pero estuviera sintácticamente roto, se habría ejecutado y el orden de `PATH` por sí solo explicaría el misterio.

**A4.2** — Bash cachea la ruta completa de cada comando que ejecuta en una tabla hash (la opción `hashall`/`-h`, activa por defecto) para evitar un escaneo de `PATH` por invocación. Cambiar `PATH` no invalida las entradas ya cacheadas, así que la ruta obsoleta sigue ejecutándose mientras que `type -a`, que hace una búsqueda fresca, reporta la nueva. Arreglos: `hash -d lab-tool` (descartar una entrada) o `hash -r` (descartar todas). `hash -r` es también lo que necesitás después de instalar un paquete en un directorio anterior en `PATH` a donde vive una copia más vieja.

**A4.3** — Dos puntos al inicio (`:/usr/bin`), dos puntos al final (`/usr/bin:`), y dos puntos duplicados (`/usr/bin::/bin`) — cada uno contiene un campo vacío, que Bash trata como `.`, el directorio de trabajo actual. Un `.` explícito en `PATH` es la cuarta forma, igual de peligrosa. En un directorio compartido o escribible por todos, un atacante deja un ejecutable con el nombre de un comando común (`ls`, `ps`, `sudo`) y espera a que un administrador haga `cd` ahí y lo tipee; el código del atacante entonces corre con los privilegios del administrador. `PATH` nunca debe contener el directorio actual, y menos que menos para `root`.

**A4.4** — `which` es un programa externo (o, en Debian, un script de shell) que solamente busca en `PATH`. No puede ver alias, funciones de shell, builtins, ni la tabla hash, y puede leer un `PATH` diferente del que tu shell acaba de modificar. `type` es un builtin de Bash que resuelve un nombre exactamente como lo hará el shell: alias → función → builtin → tabla hash → `PATH`. **`type` — específicamente `type -a`, más `hash` — es lo autoritativo.** `command -v` es el equivalente portable y apto para scripts.

**A4.5** — `PATH` es una configuración de **entorno**: debe establecerse una vez por sesión y es heredada por cada proceso hijo, así que corresponde a `~/.profile`/`~/.bash_profile`. Volver a ejecutarla en `~/.bashrc` produce entradas duplicadas en los shells anidados. Un `alias` es una característica del shell puramente **interactiva y no heredable**: no se exporta, no es visible para los hijos, y es irrelevante para los scripts, así que debe recrearse en cada shell interactivo — que es exactamente para lo que existe `~/.bashrc`. La misma regla ubica las funciones de shell y las configuraciones de `shopt`/historial en `~/.bashrc`, y `umask`, `PATH` y otras exportaciones en `~/.profile`.

---

### Ejercicio 5 — Alias

**A5.1** — De mayor a menor: **palabra reservada** (`if`, `for`, `while`, `function`, `[[`, `time`) → **alias** → **función** → **builtin** → **archivo externo encontrado en `PATH`**. Los alias están cerca del tope porque se expanden durante el parseo, antes de que la palabra sea resuelta como comando; las palabras reservadas les ganan porque el parser reconoce primero las palabras clave.

**A5.2** — Un alias es pura **sustitución textual**: `greet World` se expandió a `echo "Hello, $1!" World`. En el shell interactivo `$1` no está establecida, así que se expandió a la cadena vacía, y `World` simplemente se agregó como un argumento más de `echo`. No hay manera de colocar un argumento en el medio de un alias. La construcción correcta es una **función**, donde `$1`, `$@` y `$#` son los parámetros posicionales propios de la función:

```bash
greet() { echo "Hello, ${1:?name required}!"; }
```

**A5.3** — Los alias se expanden **cuando se lee una línea de entrada**, no cuando se ejecuta. En la versión de una línea, `alias hi=…` y `hi` están en la misma línea de entrada, así que toda la línea fue parseada — y `hi` resuelto como palabra de comando — antes de que el builtin `alias` llegara a ejecutarse. La versión de tres líneas lee y ejecuta línea por línea, así que el alias existe cuando se lee la línea 3. La misma regla aplica a los comandos compuestos: el cuerpo de una función, un `if`, o un grupo `{ … }` se lee como una unidad única, así que un alias definido dentro no puede usarse dentro. Este es el argumento estándar para preferir funciones en cualquier archivo que deba ser autocontenido.

**A5.4** — Cualquiera de: `\ls`, `'ls'`, `"ls"`, `command ls`, `/usr/bin/ls`, o hacer `unalias ls` primero. Entrecomillar *cualquier* carácter de una palabra suprime la búsqueda de alias para esa palabra; `command` evita explícitamente alias y funciones. No hay recursión infinita porque Bash no vuelve a expandir un alias mientras ya se lo está expandiendo — el texto de reemplazo se revisa en busca de alias, pero el alias que está actualmente bajo expansión queda excluido. (La regla relacionada: la *primera* palabra del reemplazo se vuelve a revisar, lo que combinado con la regla del espacio final habilita el encadenamiento de alias.)

**A5.5** — Normalmente solo la **primera** palabra de un comando se revisa para expansión de alias. Si el último carácter del *valor* de un alias es un espacio en blanco, Bash también revisa la **siguiente** palabra para expansión de alias. Así que `please ll` expande `please` → `sudo `, y después, por el espacio final, también expande `ll` → `ls -alF`, dando `sudo ls -alF`. Sin el espacio final, `ll` se pasaría a `sudo` literalmente y `sudo` reportaría `ll: command not found` — ya que `sudo` ejecuta un programa, y `ll` no lo es.

---

### Ejercicio 6 — Funciones

**A6.1** — Cualquiera de estas tres: (1) acepta argumentos posicionales (`$1`, `$@`, `$#`) y puede ubicarlos en cualquier lado; (2) puede contener múltiples sentencias, bucles, condicionales y estado local; (3) soporta variables `local` que no se filtran a quien la llama; (4) devuelve un estado de salida significativo vía `return N`; (5) puede exportarse a shells hijos con `export -f`; (6) funciona en shells no interactivos y en scripts sin `shopt -s expand_aliases`; (7) puede recursar y puede llamar al comando que oculta mediante `command`.

**A6.2** — `local` crea una variable visible solamente dentro de la función y en las funciones que esta llama (Bash usa ámbito dinámico), y restaura cualquier valor previo cuando la función retorna. Sin eso, `dir="$1"` asigna a una variable **global**: quien llame y mantenga su propia `dir` se la vería sobrescrita silenciosamente, y el valor persistiría después de que `mkcd` retornara. En shells interactivos de larga vida y en bibliotecas sourceadas desde `~/.bashrc` esta es una fuente real de bugs intermitentes y difíciles de reproducir. Regla: toda variable dentro de una función es `local` a menos que deliberadamente busques un efecto secundario.

**A6.3** — `return N` sale de la **función** y establece `$?` en `N` (0–255); `exit N` termina todo el **proceso del shell**. Dentro de una función usada interactivamente o en una biblioteca sourceada, `exit` cierra la sesión de terminal del usuario — y por eso un archivo *sourceado* debe usar `return` para abortar. Notá que `return` en el nivel superior de un archivo sourceado es legal y detiene el sourceo (este es precisamente el mecanismo detrás de la protección no interactiva de `~/.bashrc`); en el nivel superior de un script *ejecutado* es un error.

**A6.4** — Las funciones exportadas no pueden transportarse como funciones — el entorno es una lista plana de cadenas `NAME=value`. Bash las codifica como una variable de entorno cuyo nombre es `BASH_FUNC_<name>%%` y cuyo valor es el texto literal `() { … }`; un Bash receptor ve el prefijo y vuelve a definir la función. El envoltorio raro `BASH_FUNC_`/`%%` deliberadamente **no** es un identificador de shell válido, así que ninguna asignación común puede falsificarlo. Históricamente la codificación era simplemente `name=() { … }`, y el parser evaluaba todo lo que venía después de la llave de cierre — la falla explotada por Shellshock (CVE-2014-6271, 2014). Consecuencia práctica: las funciones exportadas viajan a *todos* los procesos hijos, así que `export -f` debe usarse con moderación y deshacerse con `export -fn`.

**A6.5** — El `unset mkcd` simple elimina primero la **variable**; la función sobrevive. Solamente si no existe una variable con ese nombre elimina la función. Sé siempre explícito: `unset -v mkcd` para la variable, `unset -f mkcd` para la función.

---

### Ejercicio 7 — Listas, agrupamiento y sourceo

**A7.1**

```text
B
C
```

`false` devuelve un valor distinto de cero, así que `&& echo A` se saltea y A nunca se imprime. El estado de salida de la lista `&&` salteada sigue siendo el estado distinto de cero de `false`, así que `|| echo B` se ejecuta e imprime `B`. `;` es incondicional, así que `echo C` imprime `C`.

**A7.2** — Con `;`, el segundo comando se ejecuta sin importar si `cd` tuvo éxito. Si `/var/log` no existe o no es accesible, el shell se queda en el directorio actual y `./cleanup.sh` o bien falla o — mucho peor — ejecuta un `cleanup.sh` *distinto* contra el árbol equivocado. `&&` hace que el segundo comando dependa del éxito del primero. En scripts no interactivos la misma garantía suele expresarse como `cd /var/log || exit 1`, o globalmente con `set -e`.

**A7.3** — Los paréntesis crean un **subshell**: un proceso hijo bifurcado. Todo lo que está adentro — el cambio de directorio de trabajo, las asignaciones de variables, las opciones de `set`, las variables exportadas, los manejadores de `trap`, las redirecciones — se descarta cuando el subshell termina. Así que la garantía es que el resto del script continúa en el **directorio de trabajo original** con el entorno original, sin importar lo que haga `build.sh`. Eso es una propiedad de corrección, no de estilo. La contrapartida es un `fork()` por grupo y el hecho de que las asignaciones hechas adentro no pueden observarse afuera (el clásico bug de pérdida de variables en `while read … | ...` tiene la misma raíz).

**A7.4** — `~/.bashrc` es leído solamente por shells **interactivos**. Un script ejecutado como `./script.sh` o `bash script.sh` es no interactivo y sin login, así que nunca ve nada definido ahí. Arreglos: (1) mover `export EDITOR=vim` a `~/.profile`/`~/.bash_profile` para que se establezca una vez al iniciar sesión y sea heredado por todo descendiente, incluidos los scripts; o (2) establecerlo a nivel de sistema en `/etc/profile.d/*.sh` (o `/etc/environment` vía PAM) para todos los usuarios. Una tercera opción, hacer `source ~/.bashrc` al principio del script, es posible pero mala práctica — acopla un script a la configuración interactiva de un usuario particular.

**A7.5**

| | `source ~/.bashrc` | `bash` |
|---|---|---|
| Procesos | ninguno creado — corre en el shell actual | bifurca un proceso de shell nuevo |
| `SHLVL` | sin cambios | incrementado en 1 |
| Configuraciones eliminadas | **no** se eliminan: un alias o función que borraste del archivo sigue definido, porque sourcear solamente *agrega* | siguen presentes también en el shell nuevo — no hereda nada no exportado, pero el shell padre permanece debajo, y `exit` te devuelve a él con las configuraciones viejas |
| Costo | barato, pero acumula entradas duplicadas de `PATH` si el archivo no es idempotente | deja shells anidados; el uso repetido construye una pila |

Ninguno elimina de manera confiable una definición borrada. La única recarga limpia es `exec bash` (reemplaza el proceso actual, `SHLVL` sin cambios) o una nueva sesión de login.

---

### Ejercicio 8 — Prompts

**A8.1** — `\w` es el directorio de trabajo actual **completo** con `$HOME` abreviado a `~` (`~/lab-105.1/deep`); `\W` es solamente su **basename** (`deep`). `\h` es el nombre de host hasta el primer punto (`lab01`); `\H` es el nombre de host completo tal como está configurado (`lab01.example.com`). En sistemas con FQDN largos y árboles de directorios profundos, `\W` y `\h` mantienen el prompt corto — pero `\w` es más seguro cuando trabajás habitualmente en directorios de nombres parecidos.

**A8.2** — `\[` y `\]` encierran una secuencia de caracteres **no imprimibles**. Readline los usa para calcular el ancho visible del prompt, que necesita para saber dónde está realmente el cursor. Omitirlos hace que Readline cuente los bytes del escape ANSI como columnas visibles, así que sobreestima el ancho del prompt. Los síntomas aparecen solamente cuando una línea de comando se acerca al ancho de la terminal: la línea se corta antes de tiempo o sobrescribe el prompt, `Ctrl-a`/`Ctrl-e` y las flechas aterrizan en la columna equivocada, y recuperar entradas largas del historial corrompe visiblemente la pantalla. El bug es invisible con comandos cortos, por lo cual sobrevive en tantos prompts escritos a mano.

**A8.3** — `$?` contiene el estado de salida del *último comando ejecutado*, y es sobrescrito por cada comando posterior — incluidos el builtin `local`, un `if`, o una asignación dentro de la función. Capturarlo en la primerísima instrucción es la única forma de leer el estado del comando que el usuario realmente ejecutó. (Incluso `local rc=$?` es sutilmente seguro acá porque la expansión de `$?` en la asignación ocurre antes de que `local` establezca su propio estado; dividirlo en `local rc; rc=$?` ya sería demasiado tarde.)

**A8.4** — Exportar `PS1` no le da a un Bash hijo tu prompt de ninguna manera útil. Un shell hijo **interactivo** lee `~/.bashrc`, que normalmente asigna `PS1` incondicionalmente y por lo tanto sobrescribe lo que sea que heredó. Un shell hijo **no interactivo** desestablece `PS1` por completo — Bash usa que `PS1` esté vacía como una de las señales de no interactividad, y algunos scripts prueban `[ -z "$PS1" ]` exactamente por eso. La forma correcta de compartir un prompt es poner la asignación en `~/.bashrc` (por usuario) o en `/etc/profile.d/*.sh` protegida por una prueba de interactividad (a nivel de sitio).

**A8.5** — Comando multilínea con salto de línea → `PS2` (por defecto `> `). Salida de rastreo de `set -x` → `PS4` (por defecto `+ `; el primer carácter se repite una vez por cada nivel de indirección para mostrar la profundidad del anidamiento). El menú del builtin `select` → `PS3` (por defecto `#? `).

---

### Ejercicio 9 — Directorios esqueleto

**A9.1** — `-m` (`--create-home`) crea el directorio home y copia el esqueleto dentro. Sin `-m` en un sistema donde `/etc/login.defs` establece `CREATE_HOME no`, la cuenta se crea con un directorio home registrado en `/etc/passwd` que **no existe**: el usuario puede autenticarse, pero el shell de login arranca en `/` (o falla), no hay dotfiles presentes, `PATH` y el prompt vienen solamente de `/etc/profile`, y cualquier cosa que escriba en `$HOME` falla. `-M` fuerza lo opuesto (nunca crear), y `useradd -D`/`grep CREATE_HOME /etc/login.defs` te dice qué valor por defecto está vigente.

**A9.2** — No. `/etc/skel` es una **plantilla aplicada exactamente una vez**, al crear la cuenta; no tiene relación permanente con los directorios home existentes, y los archivos que produjo pertenecen a los usuarios, que pueden haberlos editado. El mecanismo correcto para usuarios existentes es un drop-in en `/etc/profile.d/*.sh` (shells de login) y/o el archivo interactivo a nivel de sistema (`/etc/bash.bashrc` en Debian/SUSE, `/etc/bashrc` en la familia Red Hat) — ambos se leen en cada inicio de sesión de cada usuario sin tocar sus directorios home. Para algo más complejo, usá gestión de configuración. Actualizá `/etc/skel` también, así las cuentas futuras arrancan consistentes.

**A9.3** — **La propiedad no se preserva**: `useradd` establece el propietario y el grupo al UID y GID primario del usuario nuevo en cada archivo copiado. **Los bits de permisos sí se preservan** desde `/etc/skel` — el `umask` del proceso que copia no se aplica — y por eso `/etc/skel/.ssh` tiene que ser ya `0700`, y por eso un archivo perdido legible por todos en el esqueleto se propaga a toda cuenta futura. El **directorio home en sí** es un caso aparte: su modo viene de `HOME_MODE` en `/etc/login.defs` (shadow-utils 4.7 en adelante), cayendo a `0777 & ~UMASK` en versiones más viejas. Los enlaces simbólicos y los árboles de subdirectorios se copian recursivamente.

**A9.4** — Para una invocación única: `useradd -m -k /etc/skel-ops …` (`--skel`). Como valor por defecto del sistema: la clave `SKEL=` en `/etc/default/useradd`, visible en la salida de `useradd -D`. Notá que `adduser` (el wrapper en Perl de Debian) **no** lee `/etc/default/useradd`; usa `SKEL=` en `/etc/adduser.conf`.

**A9.5** — El modo `0700` en `.ssh` mantiene las claves privadas y `authorized_keys` ilegibles para otros usuarios; un `.ssh` legible por el grupo o por todos expone material de claves y permite que otros enumeren las claves confiables. OpenSSH además impone **StrictModes** (activo por defecto): si `~`, `~/.ssh`, o `~/.ssh/authorized_keys` es escribible por grupo u otros, `sshd` **se niega silenciosamente** a usar ese archivo `authorized_keys` y cae a autenticación por contraseña — registrando el motivo solamente a nivel debug. Es un incidente frecuente del tipo "mi clave dejó de funcionar y no hay nada en el log", y un `/etc/skel` mal configurado lo reproduce en cada cuenta nueva.

---

### Ejercicio 10 — Logout, trampas no interactivas, restauración

**A10.1** — `~/.bash_logout` se ejecuta cuando un **shell de login interactivo** termina — vía `exit`, `logout`, o `Ctrl-D`. **No** se ejecuta para shells interactivos sin login (una pestaña de emulador de terminal en la mayoría de los escritorios), para shells o scripts no interactivos, ni cuando el shell es matado con `SIGKILL` o la terminal se destruye abruptamente. Apropiado: limpiar la consola por privacidad, volcar el historial (`history -a`), eliminar un directorio temporal de la sesión, liberar un lock de sesión. Inapropiado: cualquier cosa de la que el sistema tenga que poder depender — registro de auditoría, revocación de credenciales, desmontar almacenamiento compartido — porque el archivo se saltea trivialmente en cualquiera de los casos de arriba. Eso corresponde a un módulo `session` de PAM o a una unidad de usuario de systemd.

**A10.2** — `scp` (en su modo tradicional) y `sftp` abren un shell en el host remoto y hablan un **protocolo binario sobre stdout/stdin**. Bash, detectando que su stdin es una conexión de red, hace source de `~/.bashrc` aunque el shell sea no interactivo; el `echo` al principio de ese archivo inyecta `Welcome to lab01!` en el flujo del protocolo. El cliente interpreta esos bytes como un frame del protocolo, lee un campo de longitud sin sentido, y aborta con `Received message too long`. Cualquier cosa que escriba en **stdout** al arrancar el shell lo rompe — banners, `fortune`, `neofetch`, `stty`, un `read` interactivo. Escribir en **stderr** es sobrevivible pero igual contamina cada comando remoto. La regla general: `~/.bashrc` no debe producir salida alguna.

**A10.3** — `$-` contiene los flags de opciones actuales; el patrón `*i*` del `case` prueba si el flag interactivo `i` está presente. Si lo está, la rama vacía `;;` no hace nada y la ejecución continúa hacia el resto del archivo. Si no lo está — un shell no interactivo, por ejemplo el que `sshd` inició para `scp` — `return` detiene inmediatamente el sourceo del archivo, así que nada más se ejecuta. Se requiere `return` en lugar de `exit` porque de `~/.bashrc` se hace **source** dentro de un shell existente: `exit` terminaría ese shell, matando de plano la sesión SSH o la transferencia de `scp` en lugar de simplemente saltear la configuración.

**A10.4** — `/etc/environment` es leído por el módulo de PAM **`pam_env(8)`**, configurado como una línea `session` (o `auth`) en `/etc/pam.d/*`, y se aplica antes de que arranque cualquier shell — por eso funciona igual para inicios de sesión gráficos, `sshd` y `login`, sin importar el shell del usuario. Es una lista simple de líneas `KEY=value` y no soporta ninguna de: expansión de variables (`$HOME` queda literal, como mostró el Paso 6), sustitución de comandos, globbing, condicionales ni bucles, la palabra clave `export`, comentarios que no sean líneas completas con `#`, ni referirse a una variable definida en una línea anterior. Tampoco es específico de un shell: aplica igualmente a `zsh`, `fish` y a sesiones que no son de shell. Para un comportamiento más rico usá `/etc/security/pam_env.conf`, que sí soporta `DEFAULT`/`OVERRIDE` y expansión `@{…}`/`${…}`.

**A10.5** — Los trabajos de `cron` no son sesiones de login de PAM en el mismo sentido, y tradicionalmente `crond` no invoca `pam_env` para `/etc/environment` (el comportamiento varía según la distribución y según si `pam_env` está listado en `/etc/pam.d/crond`). Crucialmente, `cron` además ejecuta los comandos con `/bin/sh -c`, un shell **no interactivo y sin login** que no lee ni `/etc/profile` ni `~/.profile` ni `~/.bashrc`, y provee un `PATH` deliberadamente mínimo — comúnmente `/usr/bin:/bin`. Los arreglos correctos, en orden de preferencia: establecer `PATH=` explícitamente al principio del crontab (cron soporta líneas `NAME=value` directamente), o usar rutas absolutas para cada comando del trabajo, o hacer que el trabajo haga source de un archivo de entorno dedicado que le pertenezca. Nunca asumas que un trabajo de `cron` hereda el entorno interactivo de un usuario.

</details>

---

## Fuentes

- LPI — *Exam 101 Objectives, LPIC-1 version 5.0*: <https://www.lpi.org/our-certifications/exam-101-objectives/>
- LPI — *Exam 102 Objectives, LPIC-1 version 5.0* (el Tema 105.1 se evalúa en 102-500): <https://www.lpi.org/our-certifications/exam-102-objectives/>
- GNU — *Bash Reference Manual, "Bash Startup Files"*: <https://www.gnu.org/software/bash/manual/html_node/Bash-Startup-Files.html>
- GNU — *Bash Reference Manual, "Shell Variables"* (`BASH_ENV`, `PROMPT_COMMAND`, `PS1`–`PS4`, `SHLVL`): <https://www.gnu.org/software/bash/manual/html_node/Bash-Variables.html>
- GNU — *Bash Reference Manual, "Aliases"*: <https://www.gnu.org/software/bash/manual/html_node/Aliases.html>
- GNU — *Bash Reference Manual, "Shell Functions"*: <https://www.gnu.org/software/bash/manual/html_node/Shell-Functions.html>
- GNU — *Bash Reference Manual, "Lists of Commands"*: <https://www.gnu.org/software/bash/manual/html_node/Lists.html>
- GNU — *Bash Reference Manual, "Controlling the Prompt"*: <https://www.gnu.org/software/bash/manual/html_node/Controlling-the-Prompt.html>
- GNU Coreutils — *env invocation*: <https://www.gnu.org/software/coreutils/manual/html_node/env-invocation.html>
- shadow-utils — `useradd(8)`: <https://man7.org/linux/man-pages/man8/useradd.8.html>
- shadow-utils — `login.defs(5)` (`CREATE_HOME`, `HOME_MODE`, `UMASK`): <https://man7.org/linux/man-pages/man5/login.defs.5.html>
- Linux-PAM — `pam_env(8)` y `environment(5)`: <https://man7.org/linux/man-pages/man8/pam_env.8.html> · <https://man7.org/linux/man-pages/man5/environment.d.5.html>
- OpenSSH — `sshd(8)`, *StrictModes* y requisitos de permisos de `~/.ssh/authorized_keys`: <https://man.openbsd.org/sshd_config#StrictModes>