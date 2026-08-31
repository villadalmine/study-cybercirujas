# LPIC-1 — 105.2 Personalizar o escribir scripts simples
## Ejercicios de laboratorio guiados

**Habilidades objetivo:** sintaxis `sh` (bucles, tests), sustitución de comandos, manejo del estado de salida, envío condicional de correo al superusuario, selección correcta del intérprete mediante la línea shebang, y la ubicación / propiedad / ejecución / derechos SUID de los scripts.

> **Convención de portabilidad usada en todo el documento.** LPI pide *sintaxis sh estándar*. Donde una construcción es exclusiva de Bash (`[[ ]]`, `((` `))`, arrays, `$(<file)`) se marca **[bash-only]**. Todo lo que no está marcado corre bajo `dash`, `busybox sh`, `ksh` y `bash`. En Debian/Ubuntu `/bin/sh` es `dash`, así que esta distinción no es académica.

---

## Ejercicio 0 — Preparación del laboratorio

1. Creá un directorio de trabajo limpio y entrá en él:

```bash
mkdir -p ~/lab-105.2 && cd ~/lab-105.2
```

2. Identificá qué es realmente `/bin/sh` en tu sistema:

```bash
ls -l /bin/sh
readlink -f /bin/sh
```

Salida esperada en Debian/Ubuntu:

```
lrwxrwxrwx 1 root root 4 Mar 20 08:41 /bin/sh -> dash
/usr/bin/dash
```

Salida esperada en RHEL/Fedora/openSUSE:

```
lrwxrwxrwx 1 root root 4 Mar 20 08:41 /bin/sh -> bash
/usr/bin/bash
```

3. Registrá tu shell y su versión:

```bash
echo "$0"
bash --version | head -1
```

**Preguntas**

- **Q0.1** — Si `/bin/sh` es un enlace simbólico a `bash`, ¿un script que empieza con `#!/bin/sh` se comporta idénticamente a uno que empieza con `#!/bin/bash`?
- **Q0.2** — ¿Por qué `echo $0` es una forma poco confiable de descubrir bajo qué shell está corriendo un *script*?

---

## Ejercicio 1 — El shebang: cómo el kernel elige el intérprete

El mecanismo `#!` no lo implementa el shell. Lo implementa el kernel, en el manejador `binfmt_script` de `execve(2)`. Este ejercicio lo demuestra.

1. Construí un "intérprete" que no hace más que reportar los argumentos que el kernel le entrega:

```bash
cat > showargs <<'EOF'
#!/bin/sh
printf 'interpreter %s got %d argument(s):\n' "$0" "$#"
printf '  [%s]\n' "$@"
EOF
chmod 755 showargs
```

2. Construí un "script" cuyo shebang apunte a ese intérprete y pase varias opciones:

```bash
cat > demo.sh <<'EOF'
#!/home/REPLACE_ME/lab-105.2/showargs -a -b -c
this line is never executed
EOF
sed -i "s|/home/REPLACE_ME/lab-105.2|$PWD|" demo.sh
chmod 755 demo.sh
head -1 demo.sh
```

3. Ejecutalo, primero sin argumentos, después con dos:

```bash
./demo.sh
./demo.sh foo bar
```

Salida esperada (las rutas mostrarán tu propio `$PWD`):

```
interpreter /home/student/lab-105.2/showargs got 2 argument(s):
  [-a -b -c]
  [./demo.sh]
interpreter /home/student/lab-105.2/showargs got 4 argument(s):
  [-a -b -c]
  [./demo.sh]
  [foo]
  [bar]
```

4. Ahora rompé la ruta del intérprete deliberadamente y observá el error:

```bash
printf '#!/bin/bahs\necho never reached\n' > typo.sh
chmod 755 typo.sh
./typo.sh
echo "exit status: $?"
```

Esperado:

```
bash: ./typo.sh: /bin/bahs: bad interpreter: No such file or directory
exit status: 127
```

5. Reproducí el fallo de shebang más común del mundo real — un archivo guardado con finales de línea DOS:

```bash
printf '#!/bin/bash\r\necho "hello"\r\n' > crlf.sh
chmod 755 crlf.sh
head -1 crlf.sh | cat -A
./crlf.sh
echo "exit status: $?"
```

Esperado:

```
#!/bin/bash^M$
bash: ./crlf.sh: cannot execute: required file not found
exit status: 127
```

(En bash < 5.1 el mensaje es `/bin/bash^M: bad interpreter: No such file or directory`. Ambos significan lo mismo.)

6. Reparalo y confirmá:

```bash
sed -i 's/\r$//' crlf.sh     # or: dos2unix crlf.sh
head -1 crlf.sh | cat -A
./crlf.sh
```

Esperado:

```
#!/bin/bash$
hello
```

7. Compará un shebang absoluto contra la forma con `env`:

```bash
printf '#!/usr/bin/env bash\necho "interpreter: $BASH_VERSION"\n' > envshebang.sh
chmod 755 envshebang.sh
./envshebang.sh
```

**Preguntas**

- **Q1.1** — En el paso 3, ¿por qué el intérprete recibió `-a -b -c` como **un** argumento en lugar de tres? ¿Qué pasaría con ese mismo archivo en FreeBSD?
- **Q1.2** — En el paso 3 el segundo argumento es `./demo.sh`, no `demo.sh` ni una ruta absoluta. ¿Qué te dice eso sobre lo que el kernel le pasa al intérprete?
- **Q1.3** — En el paso 4 el estado de salida fue 127, y el error nombra `/bin/bahs`, no `./typo.sh`. ¿Qué componente imprimió ese mensaje, y por qué el estado es 127?
- **Q1.4** — Dá una ventaja concreta y una desventaja concreta de seguridad de `#!/usr/bin/env bash` sobre `#!/bin/bash`.
- **Q1.5** — Un archivo no tiene shebang en absoluto, es ejecutable, y lo ejecutás como `./noshebang.sh` desde una sesión interactiva de bash. ¿Qué lo ejecuta? ¿Qué pasa si ese mismo archivo se `exec()`uta desde un programa en C?

---

## Ejercicio 2 — Ubicación, propiedad, permisos y la trampa SUID

1. Escribí un script pequeño e intentá ejecutarlo antes de hacerlo ejecutable:

```bash
cat > sysinfo.sh <<'EOF'
#!/bin/sh
printf 'host      : %s\n' "$(uname -n)"
printf 'kernel    : %s\n' "$(uname -r)"
printf 'uptime    : %s\n' "$(uptime -p 2>/dev/null || cut -d. -f1 /proc/uptime)"
printf 'real uid  : %s (%s)\n' "$(id -u)"  "$(id -un)"
printf 'eff. uid  : %s (%s)\n' "$(id -u -r 2>/dev/null; id -u)" "$(id -un)"
EOF
ls -l sysinfo.sh
./sysinfo.sh
echo "exit status: $?"
```

Esperado:

```
-rw-r--r-- 1 student student  312 Aug 26 10:12 sysinfo.sh
bash: ./sysinfo.sh: Permission denied
exit status: 126
```

2. Hacelo ejecutable y corrélo de tres formas distintas:

```bash
chmod 755 sysinfo.sh
./sysinfo.sh          # execve() -> kernel reads the shebang
sh sysinfo.sh         # sh reads the file; shebang is just a comment
. ./sysinfo.sh        # sourced into the CURRENT shell
```

3. Demostrá que es `PATH` — no el archivo — lo que decide si un nombre pelado funciona:

```bash
sysinfo.sh
echo "exit status: $?"
echo "$PATH"
```

Esperado:

```
bash: sysinfo.sh: command not found
exit status: 127
```

4. Instalalo donde corresponde a un script de nivel de usuario, y refrescá la tabla hash de comandos del shell:

```bash
mkdir -p ~/.local/bin
install -m 0755 sysinfo.sh ~/.local/bin/sysinfo
case ":$PATH:" in *":$HOME/.local/bin:"*) : ;; *) PATH="$HOME/.local/bin:$PATH" ;; esac
hash -r
command -v sysinfo
sysinfo
```

5. Instalá una copia *a nivel de sistema* con la propiedad correcta, e inspeccioná los directorios convencionales:

```bash
sudo install -o root -g root -m 0755 sysinfo.sh /usr/local/bin/sysinfo
ls -l /usr/local/bin/sysinfo
```

Esperado:

```
-rwxr-xr-x 1 root root 312 Aug 26 10:19 /usr/local/bin/sysinfo
```

6. **El experimento SUID.** Intentá darle al script privilegios de root mediante el bit setuid:

```bash
sudo chown root:root /usr/local/bin/sysinfo
sudo chmod 4755 /usr/local/bin/sysinfo
ls -l /usr/local/bin/sysinfo
/usr/local/bin/sysinfo
```

Esperado:

```
-rwsr-xr-x 1 root root 312 Aug 26 10:19 /usr/local/bin/sysinfo
host      : workstation
kernel    : 6.8.0-40-generic
uptime    : up 3 hours, 12 minutes
real uid  : 1000 (student)
eff. uid  : 1000 (student)
```

El bit `s` está puesto en disco, y no hizo **nada**.

7. Confirmá que el mismo archivo funciona como root mediante el mecanismo soportado:

```bash
sudo /usr/local/bin/sysinfo | grep uid
```

Esperado:

```
real uid  : 0 (root)
eff. uid  : 0 (root)
```

8. Limpiá el bit peligroso:

```bash
sudo chmod 0755 /usr/local/bin/sysinfo
ls -l /usr/local/bin/sysinfo
```

9. Encontrá cada archivo setuid que ya existe en el sistema — la auditoría que deberías saber ejecutar:

```bash
sudo find /usr /bin /sbin -perm /4000 -type f -printf '%M %u %p\n' 2>/dev/null | head -20
```

10. Verificá si un directorio temporal común siquiera permitiría la ejecución:

```bash
findmnt -no TARGET,OPTIONS /tmp
```

Si las opciones contienen `noexec`, un script con `chmod 755` bajo `/tmp` igual no puede ejecutarse mediante `./script`.

**Preguntas**

- **Q2.1** — El paso 1 dio estado de salida 126 y el paso 3 dio 127. Definí ambos con precisión.
- **Q2.2** — En el paso 2 corriste el script de tres formas. ¿Cuál puede cambiar el valor de `PWD` o `PATH` en tu shell *interactivo*, y por qué?
- **Q2.3** — En el paso 2, si el archivo tuviera `#!/bin/bash` pero ejecutaras `sh sysinfo.sh` en Debian, ¿qué intérprete corre el código?
- **Q2.4** — ¿Por qué el bit setuid no tuvo efecto en el paso 6? Citá el mecanismo, no solo el resultado.
- **Q2.5** — Tenés que permitir que un grupo de mesa de ayuda reinicie un servicio como root. Ordená estos tres diseños de peor a mejor y justificá: (a) script de shell setuid, (b) wrapper en C setuid que llama al script de shell, (c) una regla en `sudoers`.
- **Q2.6** — ¿Cuál es la diferencia de intención entre `/usr/local/bin` y `/usr/local/sbin`, y qué modo de permisos elegirías para un script de mantenimiento exclusivo de root?
- **Q2.7** — ¿Por qué fue necesario `hash -r` en el paso 4?

---

## Ejercicio 3 — Estado de salida: `$?`, `&&`, `||` y pipelines

1. Observá el estado de comandos exitosos y fallidos:

```bash
true;  echo "true  -> $?"
false; echo "false -> $?"
ls /etc/hostname >/dev/null; echo "ls ok      -> $?"
ls /no/such/file 2>/dev/null; echo "ls missing -> $?"
grep -q root /etc/passwd; echo "grep found     -> $?"
grep -q zzzzz /etc/passwd; echo "grep not found -> $?"
grep -q root /no/such/file 2>/dev/null; echo "grep error     -> $?"
```

Esperado:

```
true  -> 0
false -> 1
ls ok      -> 0
ls missing -> 2
grep found     -> 0
grep not found -> 1
grep error     -> 2
```

2. Observá un estado producido por una señal:

```bash
sh -c 'kill -TERM $$'; echo "SIGTERM -> $?"
sh -c 'kill -KILL $$'; echo "SIGKILL -> $?"
kill -l 15
```

Esperado:

```
SIGTERM -> 143
SIGKILL -> 137
TERM
```

3. Construí cadenas condicionales y notá la trampa:

```bash
test -f /etc/passwd && echo "passwd exists"
test -f /etc/nope   || echo "nope is missing"
test -d /etc && echo "A" || echo "B"
test -d /etc && false || echo "C RAN ANYWAY"
```

Esperado:

```
passwd exists
nope is missing
A
C RAN ANYWAY
```

4. Capturá y reusá un estado *antes* de que sea destruido:

```bash
grep -q '^nosuchuser:' /etc/passwd
rc=$?
echo "still have it: $rc"
echo "but now \$? is: $?"
```

Esperado:

```
still have it: 1
but now $? is: 0
```

5. Descubrí qué reporta un pipeline:

```bash
false | true; echo "pipeline status: $?"
echo "PIPESTATUS: ${PIPESTATUS[@]}"          # [bash-only]
set -o pipefail
false | true; echo "with pipefail : $?"
set +o pipefail
```

Esperado:

```
pipeline status: 0
PIPESTATUS: 1 0
with pipefail : 1
```

6. Escribí un script que devuelva un estado propio y significativo:

```bash
cat > checkuser.sh <<'EOF'
#!/bin/sh
# Usage: checkuser.sh <username>
# Exit: 0 = user exists, 1 = user absent, 2 = usage error
if [ "$#" -ne 1 ]; then
    echo "usage: $(basename "$0") <username>" >&2
    exit 2
fi
if getent passwd "$1" >/dev/null 2>&1; then
    echo "$1: present"
    exit 0
else
    echo "$1: absent" >&2
    exit 1
fi
EOF
chmod 755 checkuser.sh
./checkuser.sh root;        echo "-> $?"
./checkuser.sh zzzz;        echo "-> $?"
./checkuser.sh;             echo "-> $?"
./checkuser.sh a b c;       echo "-> $?"
```

Esperado:

```
root: present
-> 0
zzzz: absent
-> 1
usage: checkuser.sh <username>
-> 2
usage: checkuser.sh <username>
-> 2
```

7. Mirá a `set -e` hacer — y no hacer — lo que la gente espera:

```bash
cat > seteset.sh <<'EOF'
#!/bin/sh
set -e
echo "one"
if false; then echo "never"; fi     # set -e does NOT fire here
false || echo "two (guarded)"        # nor here
false                                # HERE it fires
echo "three: never printed"
EOF
chmod 755 seteset.sh
./seteset.sh; echo "-> $?"
```

Esperado:

```
one
two (guarded)
-> 1
```

**Preguntas**

- **Q3.1** — `grep` devolvió 0, 1 y 2 en el paso 1. ¿Qué significa cada uno, y por qué `grep -q x f || echo missing` es un bug latente?
- **Q3.2** — ¿Cuál es el rango numérico válido de un estado de salida? ¿Qué establece realmente `exit 256`, y qué establece `exit -1`?
- **Q3.3** — Explicá la línea `C RAN ANYWAY` del paso 3. Reescribí esa línea para que se comporte como un verdadero `if/then/else`.
- **Q3.4** — ¿Por qué `rc=$?` en el paso 4 debe ser la línea inmediatamente siguiente? Nombrá dos comandos que destruirían silenciosamente `$?` si se insertaran antes.
- **Q3.5** — Por defecto, ¿el estado de qué comando reporta un pipeline? ¿Qué técnica portable en POSIX te da el fallo de una etapa anterior sin `PIPESTATUS`?
- **Q3.6** — En el paso 7, enumerá los tres contextos en los que `set -e` queda suprimido.

---

## Ejercicio 4 — `test`, `[ ]` y estructuras condicionales

1. Demostrá que `[` es un comando, no sintaxis:

```bash
type -a [
ls -l /usr/bin/[
/usr/bin/[ -d /etc ] ; echo "external [ -> $?"
```

Esperado (el tamaño varía según la distribución):

```
[ is a shell builtin
[ is /usr/bin/[
-rwxr-xr-x 1 root root 59768 Mar 20 08:41 /usr/bin/[
external [ -> 0
```

2. Ejercitá los operadores de test de archivos:

```bash
touch empty.txt
echo "data" > full.txt
for op in e f d r w x s; do
    for target in /etc /etc/passwd empty.txt full.txt /no/such; do
        if [ -"$op" "$target" ]; then r=TRUE; else r=false; fi
        printf '%-12s -%s  %s\n' "$target" "$op" "$r"
    done
done
```

3. Ejercitá la comparación de cadenas y de enteros, y el clásico bug de comillas:

```bash
name="root"
[ "$name" = "root" ]  && echo "string equal"
[ "$name" != "daemon" ] && echo "string not equal"
[ -z "" ]      && echo "-z: empty string is true"
[ -n "$name" ] && echo "-n: non-empty string is true"

n=42
[ "$n" -gt 10 ] && echo "42 > 10"
[ "$n" -eq 42 ] && echo "42 == 42"
```

4. Ahora rompelo a propósito:

```bash
unset undefined_var
[ $undefined_var = "root" ]; echo "unquoted -> $?"
[ "$undefined_var" = "root" ]; echo "quoted   -> $?"

spaced="two words"
[ -n $spaced ]; echo "unquoted -n -> $?"
[ -n "$spaced" ]; echo "quoted -n   -> $?"
```

Esperado:

```
bash: [: =: unary operator expected
unquoted -> 2
quoted   -> 1
bash: [: two: binary operator expected
unquoted -n -> 2
quoted -n   -> 0
```

5. Compará `=` contra `-eq`:

```bash
a=07; b=7
[ "$a" = "$b" ]   && echo "= says equal"   || echo "= says different"
[ "$a" -eq "$b" ] && echo "-eq says equal" || echo "-eq says different"
```

Esperado:

```
= says different
-eq says equal
```

6. Construí un `if / elif / else` completo con un `case`:

```bash
cat > diskcheck.sh <<'EOF'
#!/bin/sh
# Usage: diskcheck.sh <mountpoint>
mp=${1:-/}
if [ ! -d "$mp" ]; then
    echo "not a directory: $mp" >&2
    exit 2
fi

used=$(df -P "$mp" | awk 'NR==2 {sub(/%$/,"",$5); print $5}')

if   [ "$used" -ge 95 ]; then level=CRITICAL
elif [ "$used" -ge 85 ]; then level=WARNING
elif [ "$used" -ge 70 ]; then level=NOTICE
else                          level=OK
fi

printf '%-20s %3s%%  %s\n' "$mp" "$used" "$level"

case "$level" in
    CRITICAL|WARNING) exit 1 ;;
    *)                exit 0 ;;
esac
EOF
chmod 755 diskcheck.sh
./diskcheck.sh /
./diskcheck.sh /nonexistent; echo "-> $?"
```

Esperado (los valores diferirán):

```
/                     41%  OK
not a directory: /nonexistent
-> 2
```

7. Compará el `test` portable con la palabra clave de Bash:

```bash
f="my file.txt"; touch "$f"
[ -f $f ];   echo "POSIX unquoted   -> $?"    # breaks
[ -f "$f" ]; echo "POSIX quoted     -> $?"
[[ -f $f ]]; echo "bash [[ ]] unquoted -> $?" # works: no word splitting
[[ "$f" == my* ]] && echo "bash pattern match works"
```

**Preguntas**

- **Q4.1** — `[ "$a" = "$b" ]` dijo que `07` y `7` difieren, `[ "$a" -eq "$b" ]` dijo que son iguales. Explicá, e indicá cuál usarías para comparar un UID leído de `/etc/passwd`.
- **Q4.2** — En el paso 4, ¿por qué el estado de salida del test sin comillas es `2` y no `1`? ¿Por qué importa esa distinción en un bucle `while`?
- **Q4.3** — Nombrá tres cosas que `[[ ]]` hace y `[ ]` no puede, e indicá exactamente por qué una respuesta de LPIC-1 sobre "sintaxis sh estándar" debería usar igualmente `[ ]`.
- **Q4.4** — Reescribí `[ -f "$a" -a -r "$a" ]` en la forma recomendada por POSIX, y explicá por qué `-a` / `-o` están obsoletos.
- **Q4.5** — ¿Cuál es la diferencia entre `[ -e f ]`, `[ -f f ]` y `[ -s f ]`? ¿Cuál es verdadero para `/dev/null`, `/etc` y un archivo regular vacío?
- **Q4.6** — En el paso 6, ¿por qué es necesario `used=$(... awk ... sub(/%$/,"",$5) ...)` antes de una comparación `-ge`?

---

## Ejercicio 5 — Sustitución de comandos y comillas

1. Compará las dos sintaxis:

```bash
today=$(date +%F)
today_old=`date +%F`
echo "$today / $today_old"
```

2. Demostrá por qué se prefiere `$( )` — anidamiento:

```bash
echo "kernel dir: $(dirname "$(readlink -f /boot/vmlinuz 2>/dev/null || echo /boot/none)")"
echo "backtick attempt: `echo \`echo nested\``"
```

3. Demostrá que la sustitución de comandos elimina **todos** los saltos de línea finales:

```bash
printf 'line\n\n\n\n' > trail.txt
x=$(cat trail.txt)
printf 'captured: [%s]\n' "$x"
wc -c < trail.txt
printf '%s' "$x" | wc -c
```

Esperado:

```
captured: [line]
11
4
```

4. Mostrá por qué la sustitución sin comillas es peligrosa:

```bash
mkdir -p subdir && touch "subdir/a b.txt" "subdir/c.txt"
echo "--- unquoted (word splitting) ---"
for f in $(ls subdir); do echo "  [$f]"; done
echo "--- glob (correct) ---"
for f in subdir/*;   do echo "  [$f]"; done
```

Esperado:

```
--- unquoted (word splitting) ---
  [a]
  [b.txt]
  [c.txt]
--- glob (correct) ---
  [subdir/a b.txt]
  [subdir/c.txt]
```

5. Sustitución dentro de cadenas, y expansión aritmética:

```bash
users=$(getent passwd | wc -l)
shells=$(getent passwd | cut -d: -f7 | sort -u | wc -l)
echo "There are $users accounts using $shells distinct shells."
echo "Average accounts per shell: $(( users / shells ))"
echo "Same with expr: $(expr "$users" / "$shells")"
```

6. Compará las tres formas de leer un archivo entero dentro de una variable:

```bash
a=$(cat /etc/hostname)          # portable, forks
b=$(< /etc/hostname)            # [bash-only], no fork
read -r c < /etc/hostname       # portable, first line only
echo "$a | $b | $c"
```

7. Medí el costo del fork:

```bash
time ( i=0; while [ "$i" -lt 500 ]; do x=$(echo hi); i=$((i+1)); done )
time ( i=0; while [ "$i" -lt 500 ]; do x="hi";       i=$((i+1)); done )
```

**Preguntas**

- **Q5.1** — Dá dos razones concretas por las que se prefiere `$(cmd)` sobre `` `cmd` ``.
- **Q5.2** — Un script hace `count=$(wc -l < /var/log/syslog)` y después `[ "$count" -gt 1000 ]`. Falla con `integer expression expected` en un sistema pero funciona en otro. ¿Qué es distinto, y cómo lo hacés robusto?
- **Q5.3** — ¿Por qué `for f in $(ls)` se considera un bug incluso cuando los nombres de archivo no tienen espacios? Nombrá dos modos de fallo además de los espacios.
- **Q5.4** — `x=$(printf 'a\nb\n')`. ¿Qué es `echo "$x"` frente a `echo $x`?
- **Q5.5** — ¿Cuál es la diferencia entre `$(( ))`, `$( )` y `${ }`?
- **Q5.6** — Necesitás el *stderr* de un comando en una variable. Escribí la redirección.

---

## Ejercicio 6 — Bucles: `for`, `while`, `until` y `read`

1. `for` sobre una lista literal de palabras, un glob y una secuencia generada:

```bash
for svc in sshd cron rsyslog; do
    printf '%-10s ' "$svc"
    systemctl is-active "$svc" 2>/dev/null || echo "unknown"
done

for f in /etc/*.conf; do
    printf '%8d  %s\n' "$(wc -l < "$f")" "$f"
done | sort -rn | head -5

for i in 1 2 3 4 5;      do printf '%s ' "$i"; done; echo
for i in $(seq 1 5);     do printf '%s ' "$i"; done; echo
i=1; while [ "$i" -le 5 ]; do printf '%s ' "$i"; i=$((i+1)); done; echo   # portable
for ((i=1; i<=5; i++));  do printf '%s ' "$i"; done; echo                 # [bash-only]
```

2. `for` sin lista — el `"$@"` implícito:

```bash
cat > eachargs.sh <<'EOF'
#!/bin/sh
echo "argument count: $#"
for a; do              # identical to: for a in "$@"; do
    echo "  [$a]"
done
EOF
chmod 755 eachargs.sh
./eachargs.sh one "two words" three
```

Esperado:

```
argument count: 3
  [one]
  [two words]
  [three]
```

3. `while read` — el modismo correcto para líneas de un archivo:

```bash
while IFS=: read -r user pw uid gid gecos home shell; do
    if [ "$uid" -ge 1000 ] && [ "$uid" -lt 65534 ]; then
        printf '%-16s uid=%-6s shell=%s\n' "$user" "$uid" "$shell"
    fi
done < /etc/passwd
```

4. **La trampa del subshell.** Ejecutá ambas versiones y compará:

```bash
count=0
cat /etc/passwd | while read -r line; do count=$((count+1)); done
echo "piped   : count=$count"

count=0
while read -r line; do count=$((count+1)); done < /etc/passwd
echo "redirect: count=$count"

wc -l < /etc/passwd
```

Esperado:

```
piped   : count=0
redirect: count=45
45
```

5. Demostrá por qué importan `-r` e `IFS=`:

```bash
printf 'C:\\Users\\admin\n   leading and trailing   \n' > raw.txt

while read line;        do printf 'no -r     : [%s]\n' "$line"; done < raw.txt
while read -r line;     do printf 'with -r   : [%s]\n' "$line"; done < raw.txt
while IFS= read -r line; do printf 'IFS= -r   : [%s]\n' "$line"; done < raw.txt
```

Esperado:

```
no -r     : [C:Usersadmin]
no -r     : [leading and trailing]
with -r   : [C:\Users\admin]
with -r   : [leading and trailing]
IFS= -r   : [C:\Users\admin]
IFS= -r   : [   leading and trailing   ]
```

6. `until`, `break`, `continue`, y un bucle infinito con una guarda:

```bash
cat > waitport.sh <<'EOF'
#!/bin/sh
# Usage: waitport.sh <host> <port> [timeout_seconds]
host=${1:?host required}; port=${2:?port required}; timeout=${3:-10}
elapsed=0
until nc -z -w1 "$host" "$port" 2>/dev/null; do
    if [ "$elapsed" -ge "$timeout" ]; then
        echo "timeout after ${timeout}s waiting for $host:$port" >&2
        exit 1
    fi
    sleep 1
    elapsed=$((elapsed+1))
done
echo "$host:$port is open after ${elapsed}s"
EOF
chmod 755 waitport.sh
./waitport.sh 127.0.0.1 22 3; echo "-> $?"
./waitport.sh 127.0.0.1 9999 3; echo "-> $?"
```

7. `break` / `continue` con un argumento de nivel:

```bash
for i in 1 2 3; do
    for j in a b c; do
        [ "$j" = b ] && continue
        [ "$i" = 3 ] && break 2
        echo "$i$j"
    done
done
```

Esperado:

```
1a
1c
2a
2c
```

8. Iterá sobre un resultado de `find` de forma segura — el modismo delimitado por NUL:

```bash
find /etc -maxdepth 1 -name '*.conf' -print0 |
while IFS= read -r -d '' f; do            # [bash-only: read -d]
    printf 'found: %s\n' "$f"
done | head -5

# POSIX alternative, no subshell issue, handles any filename:
find /etc -maxdepth 1 -name '*.conf' -exec sh -c '
    for f do printf "found: %s\n" "$f"; done
' sh {} + | head -5
```

**Preguntas**

- **Q6.1** — En el paso 4, ¿por qué `count` seguía en 0 después del pipeline? Nombrá dos formas de arreglarlo manteniendo un pipeline.
- **Q6.2** — ¿Qué hace exactamente `IFS=` antes de `read`, y por qué se aplica solo a ese comando?
- **Q6.3** — Sin `-r`, `read` destrozó las barras invertidas. Dá un ejemplo del mundo real donde perder `-r` corrompe datos silenciosamente.
- **Q6.4** — `for f in *.log` cuando no existe ningún archivo `.log`: ¿qué vale `$f` en la primera iteración en sh POSIX, y cómo prevenís el bug? ¿Qué opción de Bash cambia este comportamiento?
- **Q6.5** — ¿Por qué `for i in $(seq 1 100000)` es peor elección que un contador `while` en un entorno con memoria limitada?
- **Q6.6** — En el paso 6, ¿qué hace `${1:?host required}`, y en qué se diferencia de `${1:-default}` y `${1:=default}`?

---

## Ejercicio 7 — Parámetros posicionales y argumentos del script

1. Construí un script que reporte todo sobre su invocación:

```bash
cat > params.sh <<'EOF'
#!/bin/sh
echo "\$0    = $0"
echo "basename = $(basename "$0")"
echo "\$#    = $#"
echo "\$1    = $1"
echo "\$2    = $2"
echo "\$\$    = $$"
echo '--- "$@" (each arg separate) ---'
for a in "$@"; do echo "  [$a]"; done
echo '--- "$*" (all joined by IFS) ---'
for a in "$*"; do echo "  [$a]"; done
echo '--- $@ unquoted (split again) ---'
for a in $@; do echo "  [$a]"; done
EOF
chmod 755 params.sh
./params.sh alpha "beta gamma" delta
```

Esperado:

```
$0    = ./params.sh
basename = params.sh
$#    = 3
$1    = alpha
$2    = beta gamma
$$    = 28417
--- "$@" (each arg separate) ---
  [alpha]
  [beta gamma]
  [delta]
--- "$*" (all joined by IFS) ---
  [alpha beta gamma delta]
--- $@ unquoted (split again) ---
  [alpha]
  [beta]
  [gamma]
  [delta]
```

2. Consumí argumentos con `shift`:

```bash
cat > shiftdemo.sh <<'EOF'
#!/bin/sh
action=$1
[ "$#" -ge 1 ] || { echo "usage: $(basename "$0") ACTION [FILE...]" >&2; exit 2; }
shift
echo "action  = $action"
echo "remaining ($#): $*"
while [ "$#" -gt 0 ]; do
    echo "  processing: $1"
    shift
done
EOF
chmod 755 shiftdemo.sh
./shiftdemo.sh backup /etc/passwd /etc/group
```

3. Parseá opciones reales con `getopts`:

```bash
cat > optdemo.sh <<'EOF'
#!/bin/sh
verbose=0
outfile=""
usage() { echo "usage: $(basename "$0") [-v] [-o FILE] target..." >&2; exit 2; }

while getopts ':vo:h' opt; do
    case "$opt" in
        v) verbose=1 ;;
        o) outfile=$OPTARG ;;
        h) usage ;;
        :) echo "option -$OPTARG requires an argument" >&2; usage ;;
        \?) echo "unknown option: -$OPTARG" >&2; usage ;;
    esac
done
shift $((OPTIND - 1))

[ "$#" -ge 1 ] || usage
echo "verbose=$verbose outfile='${outfile:-<stdout>}' targets=$*"
EOF
chmod 755 optdemo.sh
./optdemo.sh -v -o /tmp/out.txt hostA hostB
./optdemo.sh -o
./optdemo.sh -z host; echo "-> $?"
```

Esperado:

```
verbose=1 outfile='/tmp/out.txt' targets=hostA hostB
option -o requires an argument
usage: optdemo.sh [-v] [-o FILE] target...
unknown option: -z
usage: optdemo.sh [-v] [-o FILE] target...
-> 2
```

**Preguntas**

- **Q7.1** — Enunciá la diferencia entre `"$@"` y `"$*"` en una oración, y decí cuál le pasás a un comando interno.
- **Q7.2** — ¿Por qué se requiere `shift $((OPTIND - 1))` después de un bucle `getopts`?
- **Q7.3** — ¿Qué cambia el `:` inicial en `getopts ':vo:h'`?
- **Q7.4** — `$0` era `./params.sh`. ¿Qué es `$0` cuando el mismo archivo se hace source con `. ./params.sh`? ¿Y cuando se ejecuta como `sh params.sh`?
- **Q7.5** — En sh POSIX, ¿cómo accedés al décimo parámetro posicional, y por qué `$10` no funciona?

---

## Ejercicio 8 — Envío condicional de correo al superusuario

El objetivo del examen es explícito: *realizar envío condicional de correo al superusuario*. Eso significa que el script decide —a partir de un test— si envía correo o no.

1. Verificá qué entrega de correo tenés realmente:

```bash
command -v mail mailx sendmail /usr/sbin/sendmail 2>/dev/null
ls -l /var/mail/ 2>/dev/null
```

2. Si no hay ningún MTA instalado, construí un `mail` **falso** para que el laboratorio siga siendo ejecutable:

```bash
mkdir -p ~/.local/bin
cat > ~/.local/bin/mail <<'EOF'
#!/bin/sh
echo "===== FAKE MTA ====="
echo "argv : $*"
echo "----- body -----"
cat
echo "===== END ====="
EOF
chmod 755 ~/.local/bin/mail
PATH="$HOME/.local/bin:$PATH"; hash -r
command -v mail
```

3. Enviá un correo condicional trivial desde la línea de comandos:

```bash
if [ "$(id -u)" -ne 0 ]; then
    echo "Script was run by $(id -un) at $(date -Is), not root." \
        | mail -s "privilege notice from $(uname -n)" root
fi
```

Esperado (con el MTA falso):

```
===== FAKE MTA =====
argv : -s privilege notice from workstation root
----- body -----
Script was run by student at 2026-08-26T10:41:07+02:00, not root.
===== END =====
```

4. Construí el patrón de producción — recolectar un informe y enviarlo por correo **solo si no está vacío**:

```bash
cat > diskwatch.sh <<'EOF'
#!/bin/sh
#
# diskwatch.sh - mail root when any local filesystem exceeds a threshold.
# Usage: diskwatch.sh [threshold_percent]   (default 85)
# Exit:  0 = nothing to report, 1 = alert sent, 2 = usage/internal error
#
set -u

THRESHOLD=${1:-85}
RECIPIENT=${DISKWATCH_TO:-root}
HOSTNAME=$(uname -n)

case "$THRESHOLD" in
    ''|*[!0-9]*) echo "threshold must be an integer: $THRESHOLD" >&2; exit 2 ;;
esac

report=$(mktemp "${TMPDIR:-/tmp}/diskwatch.XXXXXX") || exit 2
trap 'rm -f "$report"' EXIT HUP INT TERM

# -P forces POSIX single-line output; -l skips network filesystems.
df -P -l 2>/dev/null | awk -v t="$THRESHOLD" '
    NR > 1 && $5 + 0 >= t {
        printf "%-28s %6s used of %-10s mounted on %s\n", $1, $5, $2 "k", $6
    }
' > "$report"

if [ -s "$report" ]; then
    {
        echo "Filesystems at or above ${THRESHOLD}% on ${HOSTNAME}:"
        echo
        cat "$report"
        echo
        echo "Generated by $0 (pid $$) at $(date -Is)"
    } | mail -s "[DISK] ${HOSTNAME}: filesystem threshold ${THRESHOLD}% exceeded" "$RECIPIENT"
    logger -t diskwatch -p user.warning "threshold ${THRESHOLD}% exceeded; mailed ${RECIPIENT}"
    exit 1
fi

logger -t diskwatch -p user.info "all filesystems below ${THRESHOLD}%"
exit 0
EOF
chmod 755 diskwatch.sh
```

5. Ejercitá las tres ramas:

```bash
./diskwatch.sh 99;   echo "-> $?"     # almost certainly quiet
./diskwatch.sh 1;    echo "-> $?"     # forces the alert
./diskwatch.sh abc;  echo "-> $?"     # usage error
```

Esperado:

```
-> 0
===== FAKE MTA =====
argv : -s [DISK] workstation: filesystem threshold 1% exceeded root
----- body -----
Filesystems at or above 1% on workstation:

/dev/nvme0n1p2                  41% used of 494006272k mounted on /
/dev/nvme0n1p1                   2% used of 523248k    mounted on /boot/efi

Generated by ./diskwatch.sh (pid 28603) at 2026-08-26T10:44:19+02:00
===== END =====
-> 1
threshold must be an integer: abc
-> 2
```

6. Confirmá que el archivo temporal fue eliminado por el `trap`:

```bash
ls /tmp/diskwatch.* 2>&1
```

Esperado:

```
ls: cannot access '/tmp/diskwatch.*': No such file or directory
```

7. Verificá las entradas de syslog:

```bash
journalctl -t diskwatch -n 5 --no-pager 2>/dev/null || tail -5 /var/log/messages
```

8. Instalalo como una tarea exclusiva de root y programala:

```bash
sudo install -o root -g root -m 0750 diskwatch.sh /usr/local/sbin/diskwatch
ls -l /usr/local/sbin/diskwatch
printf '%s\n' '17 * * * * /usr/local/sbin/diskwatch 85' | sudo tee /etc/cron.d/diskwatch-tmp >/dev/null
```

> Un archivo en `/etc/cron.d/` necesita un campo de usuario. La línea correcta es:
> `17 * * * * root /usr/local/sbin/diskwatch 85`
> Corregila antes de confiar en ella, y después eliminá el archivo del laboratorio: `sudo rm -f /etc/cron.d/diskwatch-tmp`

**Preguntas**

- **Q8.1** — ¿Por qué el informe se escribe a un archivo temporal y se testea con `[ -s ]` en lugar de canalizar `awk` directamente a `mail`?
- **Q8.2** — El `trap` lista `EXIT HUP INT TERM`. ¿Por qué `EXIT` solo es insuficiente en shells más viejos, y por qué `KILL` está ausente de la lista?
- **Q8.3** — Se usa `df -P` en lugar de `df` a secas. ¿Qué bug de parseo específico previene `-P`?
- **Q8.4** — En la expresión `awk`, ¿por qué `$5 + 0 >= t` en lugar de `$5 >= t`?
- **Q8.5** — Una tarea de cron que envía correo a root es redundante si el script también escribe a stdout. Explicá la interacción entre el `MAILTO` de cron y la llamada a `mail` propia del script, y cómo evitar dos mensajes por ejecución.
- **Q8.6** — El script se instaló `0750 root:root` en `/usr/local/sbin`. Justificá cada una de esas cuatro decisiones.
- **Q8.7** — Reescribí la invocación de `mail` para que siga funcionando si `mail` no está pero `/usr/sbin/sendmail` sí.

---

## Ejercicio 9 — Depurar y validar un script

1. Verificá la sintaxis sin ejecutar:

```bash
printf '#!/bin/sh\nif [ 1 -eq 1 ]\necho broken\nfi\n' > broken.sh
sh -n broken.sh; echo "-> $?"
```

Esperado:

```
broken.sh: 4: Syntax error: "fi" unexpected (expecting "then")
-> 2
```

2. Trazá la ejecución de tres formas:

```bash
sh -x ./diskcheck.sh /
```

```bash
# Inline, scoped to a region:
cat > traced.sh <<'EOF'
#!/bin/sh
echo "quiet part"
set -x
n=$(( 2 + 3 ))
[ "$n" -gt 4 ] && result=big || result=small
set +x
echo "result=$result"
EOF
chmod 755 traced.sh
./traced.sh
```

Esperado:

```
quiet part
+ n=5
+ [ 5 -gt 4 ]
+ result=big
+ set +x
result=big
```

3. Hacé que la traza se identifique (el `PS4` de Bash):

```bash
PS4='+ ${BASH_SOURCE##*/}:${LINENO}: ' bash -x ./diskcheck.sh / 2>&1 | head
```

4. Activá las opciones de seguridad recomendadas y mirá cómo dispara cada una:

```bash
cat > strict.sh <<'EOF'
#!/bin/bash
set -euo pipefail
echo "unset variable next:"
echo "${NOT_SET}"
echo "never reached"
EOF
chmod 755 strict.sh
./strict.sh; echo "-> $?"
```

Esperado:

```
unset variable next:
./strict.sh: line 4: NOT_SET: unbound variable
-> 1
```

5. Análisis estático, si está disponible:

```bash
command -v shellcheck >/dev/null && shellcheck diskwatch.sh || echo "shellcheck not installed"
```

**Preguntas**

- **Q9.1** — ¿Cuál es la diferencia entre `sh -n`, `sh -v` y `sh -x`?
- **Q9.2** — ¿A dónde va la salida de `set -x`, y por qué `./script.sh -x > log 2>&1` se comporta distinto de `./script.sh -x > log`?
- **Q9.3** — `set -u` es amigable con Bash pero hostil al manejo de `"$@"` en Bash viejo. ¿Qué logra `${1:-}` bajo `set -u`?
- **Q9.4** — ¿Por qué `set -euo pipefail` es inapropiado en un script cuyo shebang es `#!/bin/sh` en Debian?

---

## Ejercicio 10 — Trabajo final

Escribí e instalá un único script, `svcaudit`, que satisfaga **todo** lo siguiente. Después contrastate con la implementación de referencia en las respuestas.

1. Shebang `#!/bin/sh`; ninguna construcción exclusiva de Bash en ningún lado (verificá con `dash -n svcaudit`).
2. Uso: `svcaudit [-m] [-q] SERVICE...` — `-m` envía correo a root ante un fallo, `-q` suprime stdout.
3. Usa `getopts`, después `shift $((OPTIND-1))`; sale con 2 ante error de uso.
4. Para cada servicio, usa sustitución de comandos para capturar `systemctl is-active`, y un `case` para clasificar.
5. Usa un bucle `while` sobre los parámetros posicionales restantes con `shift`.
6. Sale con 0 si todos los servicios están activos, 1 si alguno no lo está.
7. Envía correo a root **solo si** se pasó `-m` **y** al menos un servicio está caído.
8. Limpia cualquier archivo temporal con un `trap`.
9. Instalado como `/usr/local/sbin/svcaudit`, propietario `root:root`, modo `0750`.

```bash
./svcaudit -m sshd cron nosuchservice; echo "-> $?"
```

---

## Limpieza

```bash
cd ~
sudo rm -f /usr/local/bin/sysinfo /usr/local/sbin/diskwatch /usr/local/sbin/svcaudit
sudo rm -f /etc/cron.d/diskwatch-tmp
rm -f ~/.local/bin/mail ~/.local/bin/sysinfo
rm -rf ~/lab-105.2
hash -r
```

---

<details>
<summary><strong>Respuestas</strong></summary>

### Ejercicio 0

**A0.1 — No.** Cuando `bash` se invoca como `sh` (vía `argv[0]`), entra en un modo de compatibilidad tipo POSIX: no lee `~/.bashrc`, deshabilita el comportamiento de arranque específico de `bash` y apaga algunas extensiones. Más importante todavía: el *contrato de portabilidad* difiere. Un script `#!/bin/sh` es una promesa de que no necesita nada más allá de POSIX, y debe sobrevivir a ejecutarse en un sistema donde `/bin/sh` es `dash`. Probar solo en un sistema con `bash` como `sh` esconde `[[ ]]`, `local`, `+=`, arrays, `$'...'`, `source` y `echo -e` como bugs latentes.

**A0.2 —** En un shell interactivo `$0` es el nombre del shell (`bash`, `-bash`). Dentro de un script `$0` es la *ruta del script*, no el intérprete. Para encontrar el intérprete de un script en ejecución, usá `readlink /proc/$$/exe` en Linux, o verificá `$BASH_VERSION` (definida solo bajo bash).

---

### Ejercicio 1

**A1.1 —** El manejador `binfmt_script` de Linux divide la línea shebang en como máximo **dos** tokens: la ruta del intérprete, y todo lo que sigue al primer bloque de espacios en blanco como un **único** argumento, textual. No hace ninguna división en palabras. Así que `-a -b -c` llega como un solo elemento de `argv`. El `execve` de FreeBSD *sí* divide en múltiples argumentos (hasta un límite), así que el mismo archivo se comporta distinto — que es exactamente por qué la regla portable es **a lo sumo una opción en la línea shebang** (p. ej. `#!/bin/sh -e` está bien; `#!/bin/sh -e -u` no). GNU coreutils ofrece `#!/usr/bin/env -S bash -eu` (env ≥ 8.30) como escape portable.

**A1.2 —** El kernel pasa la ruta **exactamente como fue resuelta para la llamada `exec`** — acá `./demo.sh`. No se canonicaliza. Consecuencia: `$0` dentro de un script es lo que haya tipeado quien lo llamó, así que `$0` no es una forma confiable de localizar el directorio propio del script, y `basename "$0"` es la manera correcta de obtener un nombre para mostrar.

**A1.3 —** Lo imprimió el **shell**, no el kernel. `execve("./typo.sh", …)` devolvió `ENOENT` (el *intérprete* `/bin/bahs` no existe). Bash, al ver `ENOENT` después de un stat exitoso del script mismo, lee la primera línea y reporta al intérprete como el elemento faltante. El estado **127** es la convención POSIX para "comando no encontrado". Por eso un 127 con una ruta desconcertante casi siempre significa "shebang malo", y CRLF es la causa habitual.

**A1.4 —** *Ventaja:* `env` busca en `PATH`, así que el script encuentra `bash` en `/bin/bash`, `/usr/local/bin/bash` (BSD), o una compilación de `pyenv`/`nix`/Homebrew — esencial para `python3`, `perl`, `node`. *Desventaja:* hace que el intérprete quede **bajo control de quien llama**. Cualquiera que pueda influir en `PATH` elige el intérprete, lo cual es inaceptable para algo privilegiado o invocado por `sudo`/`cron`, y arruina la reproducibilidad. Regla práctica: `#!/bin/sh` y `#!/bin/bash` absolutos para scripts de sistema; `#!/usr/bin/env python3` para herramientas portables.

**A1.5 —** `execve` falla con `ENOEXEC` (ningún número mágico reconocido). POSIX requiere que un shell interactivo entonces **re-ejecute el archivo con sí mismo**, así que bash lo corre como un script de bash. Un programa en C que llama a `execve()` directamente simplemente recibe `ENOEXEC` y falla; `execvp()` de glibc reproduce el fallback del shell ejecutando `/bin/sh`. Nunca dependas de esto — escribí siempre un shebang.

---

### Ejercicio 2

**A2.1 —** **126** = el comando *se encontró* pero no pudo ejecutarse: sin permiso de ejecución, es un directorio, o el sistema de archivos está montado con `noexec`. **127** = el nombre del comando no se encontró en absoluto en `PATH`, **o** el intérprete del shebang no existe. Junto con `128+N` (terminado por la señal N) estos son los tres estados que un script nunca debe devolver por accidente.

**A2.2 —** Solo `. ./sysinfo.sh` (`source`). Hacer source ejecuta los comandos en el proceso del shell **actual**, así que `cd`, `export`, `set`, las asignaciones de variables y las definiciones de funciones persisten. `./sysinfo.sh` y `sh sysinfo.sh` ambos hacen `fork()` de un hijo; nada que cambie el hijo puede propagarse de vuelta. Por eso los archivos `/etc/profile.d/*.sh` se hacen source, no se ejecutan.

**A2.3 —** `dash`. Ejecutar `sh file` convierte la línea shebang en un comentario común — el intérprete es el que nombraste en la línea de comandos. Un script `#!/bin/bash` invocado como `sh script` chocará con errores de sintaxis en la primera construcción exclusiva de Bash. Lanzalo siempre vía `./script` o con el intérprete correcto.

**A2.4 —** El kernel de Linux **ignora deliberadamente los bits set-user-ID y set-group-ID en scripts con intérprete (`#!`)** — `execve(2)`, "Interpreter scripts". El bit permanece en el inodo (así que `ls` muestra `s` y las herramientas de auditoría lo marcan), pero las credenciales nunca cambian. La razón es una clase de carreras irreparables: entre que `execve` abre el script y el intérprete lo reabre por ruta, el archivo puede intercambiarse (un ataque por enlace simbólico), y el intérprete puede dirigirse mediante `PATH`, `IFS`, `ENV`, `BASH_ENV`, o una opción de shebang inyectada. Mecanismos correctos: `sudo`, un binario **compilado** con `setcap`/setuid que sanea el entorno, o un demonio privilegiado / unidad de systemd.

**A2.5 —** De peor a mejor:
(a) **Script de shell setuid** — ni siquiera funciona en Linux, y en sistemas donde sí funciona, es un agujero de root trivialmente explotable.
(b) **Wrapper en C setuid que llama a un script de shell** — funciona, pero simplemente moviste el problema: el wrapper debe limpiar todo el entorno (`PATH`, `IFS`, `ENV`, `BASH_ENV`, `LD_*`), usar una ruta absoluta, y el script debe seguir siendo propiedad de root y no escribible en cada componente de la ruta. Un error es root.
(c) **Regla en `sudoers`** — la respuesta correcta. `%helpdesk ALL=(root) NOPASSWD: /bin/systemctl restart nginx.service` otorga un solo comando, registra cada invocación, sanea el entorno por defecto (`env_reset`, `secure_path`), y es auditable centralmente.

**A2.6 —** `/usr/local/bin` es para comandos destinados a **todos los usuarios**; `/usr/local/sbin` para comandos destinados a la **administración del sistema** (FHS §4.9). `/usr/local/*` específicamente es la ubicación reservada para software instalado localmente, que es exactamente donde pertenecen los scripts de administración escritos a mano — nunca `/usr/bin` ni `/usr/sbin`, que pertenecen al gestor de paquetes. Un script de mantenimiento exclusivo de root debería ser `root:root` modo **`0750`** (o `0700`); `0755` dejaría que cualquier usuario *lea* lógica y rutas que pueden revelar la estructura interna, y `0775`/escribible por el grupo dejaría que un usuario no root *modifique* un script que root ejecuta — una escalada de privilegios.

**A2.7 —** Bash cachea las rutas completas de los comandos ejecutados previamente en una tabla hash. Anteponer un directorio a `PATH` no invalida ese caché, y un resultado de "no encontrado" también puede quedar recordado. `hash -r` lo limpia. Equivalentes: `hash -d nombre` para una sola entrada, o iniciar un shell nuevo.

---

### Ejercicio 3

**A3.1 —** `grep`: **0** = al menos una línea coincidió, **1** = ninguna línea coincidió (no es un error), **2** = un error real (archivo ilegible, regex inválida, archivo faltante). El bug: `grep -q x f || echo missing` imprime "missing" tanto cuando el patrón está genuinamente ausente (1) como cuando el archivo no pudo leerse en absoluto (2) — un fallo de permisos o una ruta mal tipeada se reporta silenciosamente como "la cadena no está ahí". Forma robusta:

```sh
grep -q x f
case $? in
  0) echo present ;;
  1) echo absent ;;
  *) echo "error reading f" >&2; exit 2 ;;
esac
```

**A3.2 —** 0–255 (8 bits, tal como se entrega a través de `wait(2)`). `exit 256` establece **0** (256 mod 256) — una forma espectacular de reportar éxito mientras se falla. `exit -1` establece **255**. Nunca calcules un estado de salida a partir de un conteo sin acotarlo: `[ "$errors" -gt 255 ] && errors=255`.

**A3.3 —** `cmd && A || B` **no** es if/then/else. Si `A` se ejecuta pero *falla*, `||` igual dispara y `B` también se ejecuta. En el ejemplo `test -d /etc` tuvo éxito, después `false` falló, así que `echo "C RAN ANYWAY"` se ejecutó. Correcto:

```sh
if test -d /etc; then false; else echo C; fi
```
El modismo `&&`/`||` solo es seguro cuando la rama izquierda no puede fallar (p. ej. un `echo` simple).

**A3.4 —** `$?` es sobrescrito por **cada** comando, incluidos los exitosos. Dos destructores silenciosos: `echo "checking..."` (establece `$?` en 0) y `[ "$x" = "y" ]` — y, menos obviamente, `local rc=$?` en bash (gana el estado propio del builtin `local`; escribí `local rc; rc=$?`). Capturá primero, imprimí después.

**A3.5 —** Por defecto un pipeline reporta el estado del **último** comando. Técnica portable sin `PIPESTATUS`: evitar el pipeline usando un archivo temporal o sustitución de procesos, o reestructurar para que el comando falible sea el último — p. ej. `if ! out=$(cmd1); then …; fi; printf '%s\n' "$out" | cmd2`. En bash, `set -o pipefail` hace que el pipeline devuelva el estado distinto de cero más a la derecha.

**A3.6 —** `set -e` (`errexit`) **no** dispara cuando el comando que falla es:
1. la condición de un `if`, `while` o `until`;
2. cualquier parte de una lista `&&` / `||` excepto el comando final;
3. negado con `!`.
Además no dispara para un comando dentro de un subshell cuyo estado luego se testea, y su comportamiento con funciones y sustitución de comandos es célebremente inconsistente entre shells. `set -e` es una red de contención útil, nunca un sustituto de comprobaciones explícitas de estado.

---

### Ejercicio 4

**A4.1 —** `=` es comparación de **cadenas**: las cadenas `07` y `7` son distintas. `-eq` es comparación de **enteros**: ambos se convierten a 42… a 7, así que son iguales. Para un UID leído de `/etc/passwd` usá **`-eq` / `-ge` / `-lt`**, porque estás comparando números y querés que `007` y `7` coincidan; pero primero tenés que garantizar que el valor sea numérico, o `test` aborta con estado 2.

**A4.2 —** `test` usa **0 = verdadero, 1 = falso, >1 = error**. El `[ $undefined_var = "root" ]` sin comillas se expandió a `[ = "root" ]`, que es una expresión malformada — un error de *sintaxis*, no un resultado falso, así que estado **2**. Esto importa en `while [ … ]; do` porque el shell solo distingue cero de no-cero: un error se ve idéntico a "falso", así que el bucle silenciosamente nunca corre y concluís que los datos estaban vacíos en lugar de que tu test estaba roto.

**A4.3 —** `[[ ]]` agrega: (1) sin división en palabras ni globbing en las expansiones de variables sin comillas, así que `[[ -f $f ]]` es seguro; (2) coincidencia de patrones con `==`/`!=` y regex con `=~`; (3) `&&`, `||` y paréntesis como operadores reales con precedencia adecuada; (4) comparación numérica con `<`/`>` sin escapes. **Pero** es una *palabra reservada*, no un comando, y existe solo en bash/ksh/zsh — no en `dash`, `busybox sh`, ni POSIX. LPIC-1 105.2 dice "sintaxis sh estándar", y cualquier script cuyo shebang sea `#!/bin/sh` se romperá en Debian. Usá `[ ]` con comillas disciplinadas.

**A4.4 —** `[ -f "$a" ] && [ -r "$a" ]`. POSIX marca `-a` y `-o` como obsolescentes porque `test` no puede parsear de forma confiable expresiones de más de cuatro argumentos: los operandos son indistinguibles de los operadores, así que un archivo literalmente llamado `-a` o `!` o `(` cambia cómo se parsea toda la expresión. Encadenar invocaciones separadas de `[ ]` con `&&`/`||` del shell es inequívoco y hace cortocircuito correctamente.

**A4.5 —**
- `-e f` → la ruta **existe** (de cualquier tipo: archivo, directorio, destino de enlace simbólico, dispositivo, socket).
- `-f f` → existe **y es un archivo regular**.
- `-s f` → existe **y tiene tamaño > 0**.

| ruta | `-e` | `-f` | `-s` |
|---|---|---|---|
| `/dev/null` | verdadero | **falso** (dispositivo de caracteres) | **falso** (tamaño 0) |
| `/etc` | verdadero | **falso** (directorio) | verdadero (los directorios tienen tamaño distinto de cero) |
| archivo regular vacío | verdadero | verdadero | **falso** |

Notá que `-e`/`-f` siguen los enlaces simbólicos; usá `-L` (o `-h`) para testear el enlace en sí.

**A4.6 —** `df` imprime la capacidad como `41%`. `test` con `-ge` requiere un entero puro y abortaría con `integer expression expected` (estado 2) por el `%`. `sub(/%$/,"",$5)` elimina el signo de porcentaje final dentro de `awk` para que el shell reciba `41`. La alternativa es `${used%\%}` (expansión de parámetros, elimina el sufijo) — también portable.

---

### Ejercicio 5

**A5.1 —** (1) `$( )` **anida** sin escapes; las comillas invertidas requieren escapar `` \` `` en cada nivel y se vuelven ilegibles después de dos. (2) Las comillas invertidas aplican una capa extra de procesamiento de barras invertidas, así que `\$`, `\\` y `` \` `` se comportan distinto dentro de ellas que en `$( )` — una fuente de bugs sutiles y silenciosos. (Bonus: `$( )` es visualmente inequívoco junto a `'` en la mayoría de las tipografías.)

**A5.2 —** La diferencia es `wc -l < file` (que imprime un número pelado) contra `wc -l file` (que imprime `1234 file`). Lo más probable es que el script del sistema que falla haya usado `$(wc -l file)`, o que el archivo no exista y `count` quede vacío, o que el locale haya insertado un separador de miles. Robusto:

```sh
count=$(wc -l < /var/log/syslog 2>/dev/null) || count=0
count=${count##*[! 0-9]}     # or: count=$(printf '%s' "$count" | tr -cd '0-9')
[ -n "$count" ] || count=0
[ "$count" -gt 1000 ] && …
```
Redirigí siempre *hacia dentro* de `wc` cuando querés solo el número.

**A5.3 —** `$(ls)` produce un bloque separado por saltos de línea que el shell luego somete a **división en palabras según `$IFS`** y a **globbing**. Más allá de los espacios: (1) un nombre de archivo que contenga `*` o `?` se expande de nuevo contra el directorio — un archivo llamado `*` coincide con todo; (2) un nombre de archivo que contenga un salto de línea se divide en dos "archivos"; (3) `ls` altera los caracteres no imprimibles cuando su salida no es una terminal (sustituye por `?` o pone comillas), así que el nombre que recibís de vuelta puede no ser el nombre en disco. El glob `for f in ./*` nunca pasa por la división en palabras.

**A5.4 —** `echo "$x"` imprime dos líneas, `a` y después `b`, porque las comillas preservan el salto de línea embebido. `echo $x` imprime `a b` en una sola línea: sin comillas, el valor se divide en palabras según `$IFS` (que contiene el salto de línea) en dos palabras, y `echo` une sus argumentos con un solo espacio. El salto de línea final fue eliminado por la sustitución en ambos casos.

**A5.5 —**
- `$(( expr ))` — **expansión aritmética**: evalúa aritmética de enteros, devuelve el número. `$(( 2 + 3 ))` → `5`.
- `$( cmd )` — **sustitución de comandos**: hace fork, ejecuta `cmd`, devuelve su stdout con los saltos de línea finales eliminados.
- `${ var }` — **expansión de parámetros**: el valor de una variable, más modificadores (`${v:-d}`, `${v#pat}`, `${v%pat}`, `${#v}`). Sin subproceso.

**A5.6 —** `err=$(cmd 2>&1 >/dev/null)`. El orden importa: `2>&1` primero apunta stderr al stdout actual (la tubería de la sustitución), y después `>/dev/null` redirige stdout a otro lado. Escribir `>/dev/null 2>&1` mandaría ambos a `/dev/null` y no capturaría nada.

---

### Ejercicio 6

**A6.1 —** Cada etapa de un pipeline corre en su propio **subshell** (un proceso forkeado). El bucle `while` incrementó `count` en el hijo; cuando el hijo salió, su memoria —incluida la variable— fue descartada. El `count` del padre nunca fue tocado. Arreglos que mantienen un pipeline:
1. Poner al consumidor al final y capturar su salida: `count=$(cat /etc/passwd | wc -l)`, o más en general `count=$(cmd | while read …; do …; done; echo "$count")`.
2. **[bash-only]** `shopt -s lastpipe` (requiere control de trabajos apagado, es decir, no interactivo) corre la última etapa del pipeline en el shell actual.
3. Usar un here-string o sustitución de procesos: `while read …; do …; done < <(cmd)` **[bash-only]**.
La respuesta portable es simplemente redirigir desde un archivo o usar la opción 1.

**A6.2 —** `IFS= read -r line` es una **asignación temporal de entorno** que se aplica solo a la ejecución del comando `read` y se restaura después — este es el comportamiento POSIX para una asignación de variable que precede a un *comando simple*. Poner `IFS` vacío deshabilita la división en campos dentro de `read`, así que los espacios iniciales y finales se preservan textualmente en `line`. Sin eso, `read` elimina los caracteres de `IFS` iniciales/finales (espacio, tabulación, salto de línea). Notá la excepción: como `read` es un *builtin*, algunos shells históricamente hacían que esta asignación persistiera; POSIX requiere el comportamiento temporal solo para builtins especiales — `read` es un builtin regular, así que el comportamiento temporal está garantizado.

**A6.3 —** Sin `-r`, `read` trata la barra invertida como un escape: la elimina, y una barra invertida final une silenciosamente la línea con la siguiente. Casos reales: leer rutas de Windows desde un CSV (`C:\Users\admin` → `C:Usersadmin`), leer `/etc/fstab` donde los puntos de montaje con espacios se codifican como `\040` (`/mnt/my\040disk` → `/mnt/my040disk`, y el montaje falla), y leer DNs de LDAP donde las comas van escapadas. **Usá siempre `-r`** salvo que específicamente quieras el procesamiento de escapes.

**A6.4 —** En sh POSIX, un glob sin coincidencias se deja **literalmente**: `$f` es la cadena de cuatro caracteres `*.log`, y el cuerpo del bucle corre una vez sobre un archivo que no existe. Prevención:

```sh
for f in *.log; do
    [ -e "$f" ] || continue
    …
done
```
En Bash, `shopt -s nullglob` hace que un patrón sin coincidencias se expanda a *nada* (el bucle corre cero veces), y `shopt -s failglob` lo convierte en un error.

**A6.5 —** `$(seq 1 100000)` materializa la secuencia entera como una sola cadena de ~589 KB en la memoria del shell, forkea un proceso para producirla, y después la divide en palabras en 100 000 campos — todo antes de que comience la primera iteración. Un contador `while` usa memoria O(1) y ningún fork. En sistemas busybox/embebidos `seq` puede no existir en absoluto. El `for ((i=1;i<=100000;i++))` exclusivo de bash también es O(1) pero no es portable.

**A6.6 —**
- `${1:?host required}` — si `$1` no está definido **o está vacío**, imprime `sh: 1: host required` a stderr y **sale del script** (no interactivo) con un estado distinto de cero. Usalo para argumentos obligatorios.
- `${1:-default}` — sustituye `default` **solo para esta expansión**; `$1` mismo no cambia.
- `${1:=default}` — sustituye *y* **asigna**. Falla con parámetros posicionales (`$1`, `$2`, …) — POSIX prohíbe asignarles de esta forma — así que solo es utilizable con variables con nombre.
Quitar los dos puntos (`${1?…}`, `${1-…}`) cambia el disparador de "no definida o vacía" a "solo no definida".

---

### Ejercicio 7

**A7.1 —** `"$@"` se expande a **N palabras entrecomilladas separadas**, una por parámetro posicional, preservando los espacios embebidos; `"$*"` se expande a **una sola palabra** con los parámetros unidos por el primer carácter de `$IFS` (un espacio por defecto). Pasale **`"$@"`** a un comando interno — siempre, con las comillas. `"$*"` es solo para construir una cadena de visualización.

**A7.2 —** `getopts` deja `OPTIND` apuntando al índice del **primer argumento que no es una opción**. `shift $((OPTIND - 1))` descarta las opciones consumidas y sus argumentos para que `$1`, `$@` y `$#` se refieran entonces solo a los operandos. Sin eso, `$1` sigue siendo `-v` y todo bucle posterior sobre `"$@"` reprocesa las banderas. (En un script, `OPTIND` se reinicia a 1 automáticamente al arrancar; si llamás a `getopts` dos veces en un mismo shell, reinicialo manualmente con `OPTIND=1`.)

**A7.3 —** El `:` inicial selecciona el **reporte silencioso de errores**. Sin él, `getopts` imprime su propio mensaje a stderr para opciones desconocidas y argumentos faltantes. Con él: una opción desconocida establece `opt` en `?` y pone la letra ofensora en `OPTARG`; un argumento requerido faltante establece `opt` en `:` y pone la letra en `OPTARG`. Esa es la única forma de distinguir "bandera desconocida" de "bandera sin su valor" y de emitir tu propio mensaje de uso consistente.

**A7.4 —** Cuando se hace source con `. ./params.sh`, `$0` es el `$0` **del shell que llama** (p. ej. `bash` o `-bash`) — hacer source no lo cambia, y por eso los archivos hechos source no pueden encontrar de forma confiable su propia ruta en sh POSIX. Cuando se ejecuta como `sh params.sh`, `$0` es `params.sh` (tal cual se tipeó, sin `./`).

**A7.5 —** `${10}`. El `$10` pelado se parsea como `${1}` seguido del carácter literal `0`, porque los parámetros posicionales sin llaves son de **un solo dígito**. La alternativa portable es hacer `shift` más allá de los primeros nueve, o iterar con `for a in "$@"`.

---

### Ejercicio 8

**A8.1 —** Porque tenés que decidir *si enviar o no* antes de enviar, y `mail` ya se comprometió con un mensaje para cuando lee su stdin — canalizar `awk` directamente enviaría una alerta vacía en cada ejecución. `[ -s "$report" ]` ("existe y su tamaño es mayor que cero") es exactamente el "condicional" de "envío condicional de correo". Esto además te da el informe dos veces: una en el cuerpo del correo, otra para el registro. La alternativa que evita el archivo temporal es `report=$(df … | awk …); [ -n "$report" ] && printf '%s\n' "$report" | mail …` — está bien acá, pero la forma con archivo escala a informes demasiado grandes como para mantenerlos cómodamente en una variable.

**A8.2 —** Los shells derivados de Bourne más viejos (y algunas versiones de `ksh`) **no** ejecutan el trap de `EXIT` cuando el shell es terminado por una señal — el proceso muere antes de que corra el manejador de salida. Listar `HUP INT TERM` explícitamente garantiza la limpieza cuando se cierra la terminal, el usuario presiona Ctrl-C, o `systemd`/`kill` envía `SIGTERM`. `KILL` (9) está ausente porque **`SIGKILL` no puede capturarse, bloquearse ni ignorarse** — el kernel destruye el proceso directamente. Precisamente por eso los archivos de `mktemp` pertenecen bajo `TMPDIR`/`/tmp`, donde `systemd-tmpfiles` o una limpieza al arranque eventualmente recogerán el huérfano.

**A8.3 —** El `df` a secas envuelve los nombres de dispositivo largos a una segunda línea cuando exceden el ancho de columna (p. ej. `/dev/mapper/vg_data-lv_backups`), así que `awk '{print $5}'` lee el campo equivocado o la línea equivocada. `df -P` fuerza el formato de salida POSIX: **exactamente una línea por sistema de archivos**, campos en un orden fijo (`Filesystem 1024-blocks Used Available Capacity Mounted-on`), y bloques de 1024 bytes sin importar `BLOCKSIZE`/`POSIXLY_CORRECT`. Cualquier script que parsee `df` debe usar `-P`.

**A8.4 —** `$5` es la cadena `"41%"`. En `awk`, una comparación cadena-a-número sigue reglas complejas: comparar un campo contra una variable *numérica* `t` dispara coerción numérica solo si el campo "parece numérico", y `"41%"` no lo parece — así que `$5 >= t` puede realizar una comparación de **cadenas**, en la que `"9%"` ordena después de `"41%"` y la alerta dispara en el sistema de archivos equivocado. `$5 + 0` fuerza la evaluación aritmética, y el parseo numérico de awk se detiene en el primer carácter no numérico, dando `41`. Lo explícito es lo correcto.

**A8.5 —** `cron` envía por correo **todo lo que la tarea escriba a stdout o stderr** a la dirección en `MAILTO` (o al dueño del crontab si no está definida). Si el script además llama a `mail` por su cuenta, root recibe dos mensajes por el mismo evento. Resoluciones, elegí una:
- Mantener el `mail` propio del script (mejor: controlás asunto, destinatario y formato) y hacer que el script sea **silencioso en stdout** — mandá toda la salida para humanos al log vía `logger`, o redirigí en el crontab: `17 * * * * root /usr/local/sbin/diskwatch 85 >/dev/null 2>&1`. Ojo: esa redirección también esconde caídas genuinas, así que combinala con `logger`.
- O eliminar la llamada a `mail`, dejar que el script imprima el informe a stdout solo cuando hay algo que reportar, y dejar que cron haga el envío vía `MAILTO=root`. Lo más simple, pero perdés el control de la línea de asunto.
Poner `MAILTO=""` en el crontab deshabilita por completo el envío de correo de cron.

**A8.6 —** *`/usr/local/sbin`*: es un comando de administración del sistema (lee todos los sistemas de archivos y envía correo a root), no un comando de usuario, y está escrito localmente, así que pertenece bajo `/usr/local` en lugar de `/usr/sbin`, que es propiedad del gestor de paquetes. *propietario `root`*: cron lo ejecuta como root; un script que root ejecuta no debe ser escribible por nadie más. *grupo `root`*: la misma razón — un archivo escribible por el grupo es un shell de root para cada miembro de ese grupo. *modo `0750`*: `rwx` para root, `r-x` para el grupo (acá, solo root), **nada para el resto** — no hay razón para que usuarios comunes lean umbrales internos, destinatarios o rutas, ni razón para que lo ejecuten.

**A8.7 —**

```sh
send_mail() {   # send_mail <subject> <recipient>; body on stdin
    if command -v mail >/dev/null 2>&1; then
        mail -s "$1" "$2"
    elif [ -x /usr/sbin/sendmail ]; then
        {
            printf 'To: %s\n' "$2"
            printf 'Subject: %s\n' "$1"
            printf 'Auto-Submitted: auto-generated\n\n'
            cat
        } | /usr/sbin/sendmail -t
    else
        logger -t diskwatch -p user.err "no MTA available; alert dropped"
        return 1
    fi
}
```
`sendmail -t` lee los destinatarios del bloque de cabeceras, así que tenés que emitir `To:` y una línea en blanco antes del cuerpo. `Auto-Submitted: auto-generated` (RFC 3834) evita que los autorespondedores de vacaciones respondan a tu monitoreo.

---

### Ejercicio 9

**A9.1 —** `-n` (`noexec`): parsea el script entero y reporta errores de sintaxis **sin ejecutar nada** — la verificación previa obligatoria para cualquier script que estés por instalar. `-v` (`verbose`): repite cada línea de la entrada **tal como se lee**, antes de la expansión. `-x` (`xtrace`): repite cada comando **después** de la expansión, precedido por `$PS4`, a medida que se ejecuta. Usá `-n` para validar, `-x` para depurar, `-v` rara vez (te muestra lo que escribiste, que ya tenés).

**A9.2 —** `set -x` escribe a **stderr** (descriptor de archivo 2), no a stdout — deliberadamente, para que la traza nunca contamine la salida de datos de un script. Notá también que `./script.sh -x` **no** activa el trazado en absoluto: `-x` se le pasa al script como `$1`. Para trazar, ejecutá `sh -x ./script.sh` o poné `set -x` en el script. En cuanto a la redirección: `> log` captura solo stdout, dejando la traza en la terminal; `> log 2>&1` fusiona la traza en el mismo archivo, intercalada con la salida — que es lo que normalmente querés al depurar una tarea de cron.

**A9.3 —** Bajo `set -u` (`nounset`), referenciar una variable no definida es un error fatal. `$1` está sin definir cada vez que el script se llama sin argumentos, así que `if [ -z "$1" ]` aborta en lugar de reportar un error de uso. `${1:-}` se expande a la cadena vacía cuando `$1` está sin definir, suprimiendo el fallo de `nounset` y permitiéndote igual testear si está vacío. El mismo modismo para `"${@:-}"` en Bash < 4.4, donde `"$@"` con cero parámetros también hacía saltar `-u`.

**A9.4 —** `pipefail` **no es POSIX** — `dash` no lo implementa, y `set -o pipefail` falla con `Illegal option -o pipefail`, abortando el script en su primera línea. `set -e` y `set -u` son POSIX y funcionan en `dash`, pero el comportamiento exacto de `-u` alrededor de `"$@"` varía. Para `#!/bin/sh` la red de seguridad portable es `set -eu` más comprobaciones explícitas de estado alrededor de cada pipeline. Si querés `pipefail`, cambiá el shebang a `#!/bin/bash` y asumilo.

---

### Ejercicio 10 — Implementación de referencia

```sh
#!/bin/sh
#
# svcaudit - report systemd services that are not active.
# Usage: svcaudit [-m] [-q] SERVICE...
#   -m  mail root if any service is down
#   -q  suppress normal stdout
# Exit: 0 all active, 1 at least one not active, 2 usage/internal error
#
set -u

do_mail=0
quiet=0
report=""

usage() {
    echo "usage: $(basename "$0") [-m] [-q] SERVICE..." >&2
    exit 2
}

cleanup() { [ -n "$report" ] && rm -f "$report"; }
trap cleanup EXIT HUP INT TERM

while getopts ':mqh' opt; do
    case "$opt" in
        m)  do_mail=1 ;;
        q)  quiet=1 ;;
        h)  usage ;;
        :)  echo "option -$OPTARG requires an argument" >&2; usage ;;
        \?) echo "unknown option: -$OPTARG" >&2; usage ;;
    esac
done
shift $((OPTIND - 1))

[ "$#" -ge 1 ] || usage

report=$(mktemp "${TMPDIR:-/tmp}/svcaudit.XXXXXX") || exit 2
failures=0

while [ "$#" -gt 0 ]; do
    svc=$1
    shift
    state=$(systemctl is-active "$svc" 2>/dev/null) || true
    case "$state" in
        active)
            [ "$quiet" -eq 1 ] || printf '%-24s %s\n' "$svc" "OK ($state)"
            ;;
        activating|reloading)
            [ "$quiet" -eq 1 ] || printf '%-24s %s\n' "$svc" "TRANSIENT ($state)"
            ;;
        *)
            [ "$quiet" -eq 1 ] || printf '%-24s %s\n' "$svc" "DOWN (${state:-unknown})"
            printf '%-24s %s\n' "$svc" "${state:-unknown}" >> "$report"
            failures=$((failures + 1))
            ;;
    esac
done

if [ "$failures" -gt 0 ]; then
    if [ "$do_mail" -eq 1 ] && [ -s "$report" ]; then
        {
            printf 'Service audit on %s at %s\n\n' "$(uname -n)" "$(date -Is)"
            printf '%d service(s) not active:\n\n' "$failures"
            cat "$report"
        } | mail -s "[SVC] $(uname -n): $failures service(s) not active" root
    fi
    logger -t svcaudit -p user.warning "$failures service(s) not active"
    exit 1
fi

logger -t svcaudit -p user.info "all requested services active"
exit 0
```

Validar e instalar:

```bash
dash -n svcaudit && echo "POSIX syntax OK"
sudo install -o root -g root -m 0750 svcaudit /usr/local/sbin/svcaudit
```

Ejecución esperada:

```
sshd                     OK (active)
cron                     OK (active)
nosuchservice            DOWN (inactive)
===== FAKE MTA =====
argv : -s [SVC] workstation: 1 service(s) not active root
----- body -----
Service audit on workstation at 2026-08-26T11:07:52+02:00

1 service(s) not active:

nosuchservice            inactive

===== END =====
-> 1
```

Puntos de la implementación que vale la pena señalar:
- `state=$(systemctl is-active "$svc") || true` — `is-active` **sale con un estado distinto de cero** cuando la unidad no está activa, lo que bajo `set -e` mataría el script; `|| true` lo neutraliza mientras el valor igual queda capturado.
- `${state:-unknown}` cubre el caso en que `systemctl` no produce salida alguna (unidad no encontrada en algunas versiones).
- `cleanup()` se protege con `[ -n "$report" ]` porque el trap se instala *antes* de que corra `mktemp` — una salida temprana por `usage` no debe hacer `rm -f ""`.
- `while [ "$#" -gt 0 ]; …; shift` se usa en lugar de `for svc in "$@"` puramente para satisfacer el requisito 5; `for svc do` es la forma idiomática.

</details>

---

## Fuentes

- LPI — Exam 101-500 Objectives: <https://www.lpi.org/our-certifications/exam-101-objectives/>
- LPI — Exam 102-500 Objectives (el tema 105.2 vive acá): <https://www.lpi.org/our-certifications/exam-102-objectives/>
- The Open Group — POSIX.1-2017, Shell Command Language: <https://pubs.opengroup.org/onlinepubs/9699919799/utilities/V3_chap02.html>
- GNU Bash Reference Manual: <https://www.gnu.org/software/bash/manual/bash.html>
- `execve(2)` — scripts con intérprete, y la omisión de set-user-ID en scripts: <https://man7.org/linux/man-pages/man2/execve.2.html>
- `test(1)` / `test` de POSIX: <https://man7.org/linux/man-pages/man1/test.1.html> · <https://pubs.opengroup.org/onlinepubs/9699919799/utilities/test.html>
- `getopts` (POSIX): <https://pubs.opengroup.org/onlinepubs/9699919799/utilities/getopts.html>
- `df(1)` y el formato de salida POSIX `-P`: <https://pubs.opengroup.org/onlinepubs/9699919799/utilities/df.html>
- `mailx(1p)` — la interfaz de correo POSIX: <https://man7.org/linux/man-pages/man1/mailx.1p.html>
- `crontab(5)` — `MAILTO` y el manejo de la salida de las tareas: <https://man7.org/linux/man-pages/man5/crontab.5.html>
- Filesystem Hierarchy Standard 3.0, §4.9 `/usr/local`: <https://refspecs.linuxfoundation.org/FHS_3.0/fhs/ch04s09.html>
- Sudo — `sudoers(5)`: <https://www.sudo.ws/docs/man/sudoers.man/>
- ShellCheck: <https://www.shellcheck.net/>