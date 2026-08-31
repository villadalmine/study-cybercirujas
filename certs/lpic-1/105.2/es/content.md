# LPIC-1 · Tema 105.2 — Personalizar o escribir scripts simples

**Examen:** 102-500 (LPIC-1 v5.0) · **Objetivo 105.2** · Tema 105 *Shells y scripting de shell*

**Áreas de conocimiento clave cubiertas aquí:** sintaxis estándar de `sh` (bucles, tests), sustitución de comandos, comprobación de valores de retorno para éxito/fallo u otra información provista por un comando, envío condicional de correo al superusuario, selección correcta del intérprete mediante la línea shebang (`#!`), y gestión de la ubicación, propiedad, ejecución y derechos `suid` de los scripts.

**Términos y utilidades en alcance:** `for`, `while`, `test`, `if`, `read`, `seq`, `exec`, `||`, `&&`, `;`, `exit`, `set`, `declare`, `.` (source), funciones de shell.

---

## 1. El problema de producción: el shell es el sustrato que nadie audita

Cada capa de una plataforma moderna termina en un script de shell, lo admita alguien o no:

| Capa | Dónde vive realmente el script | Qué se rompe cuando está mal |
|---|---|---|
| Imagen de contenedor | `ENTRYPOINT ["/entrypoint.sh"]` | PID 1 no reenvía `SIGTERM`; los pods tardan el `terminationGracePeriodSeconds` completo en morir, las actualizaciones progresivas se arrastran |
| Probes de Kubernetes | `exec: command: ["/bin/sh","-c","..."]` | Un probe que siempre sale con 0 enmascara un proceso muerto; un probe que sale distinto de cero ante un fallo transitorio dispara una tormenta de reinicios |
| Batch | `CronJob` → `command`, o `/etc/cron.daily/<name>` | El job "tiene éxito" mientras no hace nada; pérdida silenciosa de datos |
| Bootstrap de nodo | cloud-init, `%post`, Ignition, `shell:` de Ansible | El nodo se une al clúster a medio configurar |
| CI/CD | Bloques `script:` en GitLab CI, `run:` en GitHub Actions | El pipeline se pone en verde con un paso de build fallido |
| Systemd | `ExecStart=`, `ExecStartPre=`, `OnFailure=` | La unidad reporta `active (exited)` mientras el trabajo nunca se ejecutó |

La propiedad arquitectónica que importa es esta: **la API pública de un script de shell es su exit status, y su superficie de observabilidad es stdout/stderr.** Todo lo de arriba — Kubernetes, systemd, cron, CI — es un supervisor que toma decisiones de planificación, reinicio, alerta y rollback a partir de un único entero entre 0 y 255. Un script que devuelve 0 después de fallar no es un bug en el script; es una **señal de control corrupta** propagada hacia el orquestador, y derrota todo mecanismo de reintento, alerta y rollback construido encima.

Tres clases de fallo causan la abrumadora mayoría de los incidentes de producción atribuibles a código de shell:

1. **Fallo silencioso** — el script continúa después de un error, y el último comando (a menudo `echo` o `rm`) devuelve 0. El supervisor registra éxito.
2. **Intérprete equivocado** — el script fue escrito y probado bajo `bash` pero el shebang dice `#!/bin/sh`, que en Debian/Ubuntu es `dash`. O el archivo fue editado en Windows y arrastra finales de línea CRLF. El kernel se niega a hacer exec, o el shell falla en construcciones que el autor creía universales.
3. **Expansión sin comillas** — una variable que contiene un espacio, un carácter de glob o un salto de línea es dividida en palabras por el shell en múltiples argumentos. El caso terminal clásico es `rm -rf $DIR/` donde `DIR` está vacía.

Este objetivo trata de eliminar las tres de manera determinista, con comprobaciones estáticas gratuitas, antes de que el código llegue siquiera a un nodo.

---

## 2. El contrato del intérprete: qué hace realmente `#!`

### 2.1 Mecánica del kernel

`#!` no es una característica del shell. Lo maneja el kernel, en `fs/binfmt_script.c`. Cuando se llama a `execve(2)` sobre un archivo regular con el bit de ejecución activo, el kernel lee los primeros bytes:

* Si son `\x7fELF`, lo maneja `binfmt_elf`.
* Si son `#!` (bytes `0x23 0x21`), `binfmt_script` lee el resto de la primera línea, la divide en una ruta de intérprete más **como máximo un** argumento, y re-ejecuta como `interpreter [optional-arg] script-path [original args...]`.
* En caso contrario `execve` devuelve `ENOEXEC`.

Consecuencias que muerden en producción:

| Propiedad | Comportamiento | Regla práctica |
|---|---|---|
| Límite de longitud de línea | La primera línea se trunca al `BINPRM_BUF_SIZE` del kernel (128 bytes históricamente, 256 en kernels actuales) | Nunca dependas de shebangs largos; mantenelos cortos |
| Cantidad de argumentos | Linux pasa **todo lo que va después del intérprete como un único argumento** | `#!/usr/bin/env python3 -u` pasa `"python3 -u"` como un solo arg a `env` → falla |
| `env -S` | GNU coreutils ≥ 8.30 `env -S` divide la cadena por sí mismo | `#!/usr/bin/env -S python3 -u` funciona en sistemas GNU, no en BusyBox/BSD |
| Sin shebang | `execve` → `ENOEXEC`. Un `bash` interactivo detecta esto y vuelve a ejecutar el archivo con una copia de sí mismo; un programa en C o un `execve` desde otro lenguaje simplemente falla | Escribí siempre un shebang |
| Intérprete relativo | `#!bash` se resuelve relativo al CWD del llamador, no a `PATH` | Siempre absoluto, o `env` |

```
$ head -c 2 /usr/local/sbin/rotate-artifacts | xxd
00000000: 2321                                     #!

$ file /usr/local/sbin/rotate-artifacts
/usr/local/sbin/rotate-artifacts: Bourne-Again shell script, ASCII text executable
```

### 2.2 Las tres firmas de diagnóstico

```
$ ./deploy.sh
bash: ./deploy.sh: /bin/bash^M: bad interpreter: No such file or directory
```
Finales de línea CRLF. El kernel tomó `/bin/bash\r` como ruta del intérprete. Confirmá y arreglá:

```
$ file deploy.sh
deploy.sh: Bourne-Again shell script, ASCII text executable, with CRLF line terminators

$ sed -i 's/\r$//' deploy.sh
$ file deploy.sh
deploy.sh: Bourne-Again shell script, ASCII text executable
```

```
$ ./collect.sh; echo "rc=$?"
bash: ./collect.sh: /usr/bin/pythn3: bad interpreter: No such file or directory
rc=126
```
Error de tipeo o intérprete ausente en una imagen slim. Exit status **126** = encontrado pero no ejecutable.

```
$ ./collect.sh; echo "rc=$?"
bash: ./collect.sh: Permission denied
rc=126

$ ls -l collect.sh
-rw-r--r--. 1 sre sre 812 Aug 26 09:14 collect.sh
$ chmod 0755 collect.sh
$ ./collect.sh; echo "rc=$?"
rc=0
```

### 2.3 `#!/bin/sh` vs `#!/bin/bash` vs `#!/usr/bin/env bash`

| Shebang | Resuelve a | Portable | Velocidad / tamaño | Cuándo usarlo |
|---|---|---|---|---|
| `#!/bin/sh` | `dash` en Debian/Ubuntu, `bash` en modo POSIX en RHEL ≤ 8, `busybox ash` en Alpine | Máxima | Arranque más rápido, imagen más chica | Scripts de init, entrypoints de contenedor, cualquier cosa que deba correr en una imagen distroless/Alpine |
| `#!/bin/bash` | Siempre GNU bash, ruta fija | Falla donde bash está en `/usr/local/bin/bash` (BSD) o ausente (Alpine no trae `bash` instalado) | ~3–5× más lento al arrancar que dash | Scripts de sistema en una distro que controlás |
| `#!/usr/bin/env bash` | El primer `bash` en `PATH` | Mejor para laptops de desarrolladores y BSD | Igual que arriba + un exec extra | Herramientas, helpers de CI |
| `#!/usr/bin/env -S bash -euo pipefail` | Solo GNU coreutils ≥ 8.30 | Pobre | — | Evitalo; poné `set` en la línea 2 en su lugar |

**La trampa:** `#!/usr/bin/env bash` busca en `PATH`. Bajo `sudo` con `secure_path` configurado, o en una unidad de systemd donde `PATH` es `/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin`, ese puede no ser el `bash` con el que probaste. Para cualquier cosa invocada por un supervisor, preferí la ruta absoluta y fijá el entorno en el archivo de unidad.

Para LPIC-1 y para código de plataforma portable, **`#!/bin/sh` más sintaxis estrictamente POSIX es el default defendible**, y el resto de este documento marca cada bashism explícitamente.

---

## 3. Elegir el dialecto: POSIX `sh` vs `bash`

Debian y Ubuntu enlazan `/bin/sh` a `dash` (Debian Almquist Shell) precisamente porque es pequeño y rápido — recorta tiempo medible del boot, donde corren miles de scripts pequeños. Alpine usa BusyBox `ash`. Ninguno es bash. La siguiente tabla es el artefacto más valioso de este objetivo:

| Construcción | POSIX `sh` (dash/ash) | bash | Reemplazo portable |
|---|---|---|---|
| `[[ x == y ]]` | ✗ `[[: not found` | ✓ | `[ "$x" = "$y" ]` |
| `==` dentro de `[ ]` | ✗ (dash lo acepta, pero no es estándar) | ✓ | `=` |
| `(( n > 3 ))` | ✗ | ✓ | `[ "$n" -gt 3 ]` |
| `$(( n + 1 ))` | ✓ | ✓ | — |
| `arr=(a b c)` | ✗ | ✓ | Parámetros posicionales `set -- a b c` |
| `${var,,}` / `${var^^}` | ✗ | ✓ (4.0+) | `tr '[:upper:]' '[:lower:]'` |
| `${var/foo/bar}` | ✗ | ✓ | `sed` / `${var#...}` `${var%...}` |
| `source file` | ✗ | ✓ | `. ./file` |
| `function f { }` | ✗ | ✓ | `f() { ... }` |
| `local` | ✓ *(extensión de dash/ash, no POSIX-2018; POSIX-2024 lo agrega)* | ✓ | Usalo; universalmente disponible en la práctica |
| `echo -n` / `echo -e` | Comportamiento indefinido | ✓ | `printf '%s' "$x"` |
| `set -o pipefail` | ✗ en dash (agregado a POSIX Issue 8, 2024) | ✓ | Comprobaciones explícitas de status, o FIFOs |
| `${PIPESTATUS[@]}` | ✗ | ✓ | — |
| `trap ... ERR` | ✗ | ✓ | `set -e` + `trap ... EXIT` |
| `$RANDOM`, `$SECONDS`, `$EPOCHSECONDS` | ✗ | ✓ | `od -An -N2 -tu2 /dev/urandom`, `date +%s` |
| `<<<"here string"` | ✗ | ✓ | `printf '%s\n' "$x" \|` o heredoc |
| `&>file` | ✗ | ✓ | `>file 2>&1` |
| Sustitución de procesos `<(cmd)` | ✗ | ✓ | Archivo temporal / FIFO |
| `read -a`, `read -d` | ✗ | ✓ | `IFS` + `set --` |
| `wait -n`, `mapfile` | ✗ | ✓ | — |

Demostrando el costo de equivocarse:

```
$ cat > /tmp/check.sh <<'EOF'
#!/bin/sh
if [[ "$1" == "prod" ]]; then
    echo "production"
fi
EOF
$ chmod +x /tmp/check.sh

$ bash /tmp/check.sh prod
production

$ dash /tmp/check.sh prod
/tmp/check.sh: 2: [[: not found

$ dash /tmp/check.sh prod; echo "rc=$?"
/tmp/check.sh: 2: [[: not found
rc=0
```

Fijate bien en la última línea. **El script falló y aun así salió con 0**, porque el `if` simplemente tomó la rama falsa después de que el comando no fuera encontrado. Una compuerta de CI o una unidad de systemd reportarían éxito. Esta es la clase de fallo #1 y #2 combinadas, y se detecta gratis:

```
$ checkbashisms /tmp/check.sh
possible bashism in /tmp/check.sh line 2 (alternative test command ([[ foo ]] should be [ foo ])):
if [[ "$1" == "prod" ]]; then

$ shellcheck -s sh /tmp/check.sh

In /tmp/check.sh line 2:
if [[ "$1" == "prod" ]]; then
   ^-- SC3010 (warning): In POSIX sh, [[ ]] is undefined.
                ^-- SC3014 (warning): In POSIX sh, == in place of = is undefined.

For more information:
  https://www.shellcheck.net/wiki/SC3010 -- In POSIX sh, [[ ]] is undefined.
  https://www.shellcheck.net/wiki/SC3014 -- In POSIX sh, == in place of = is...
```

---

## 4. Exit status: la verdadera API del script

### 4.1 El espacio de status

| Rango | Significado | Origen |
|---|---|---|
| `0` | Éxito | Convención, impuesta por todo supervisor |
| `1` | Fallo genérico | Convención |
| `2` | Mal uso de un builtin del shell / error de uso | Convención de bash |
| `1`–`125` | Definido por la aplicación | Tuyos para asignar |
| `126` | Comando encontrado pero no ejecutable (permisos, intérprete inválido) | Shell |
| `127` | Comando no encontrado | Shell |
| `128+N` | Terminado por la señal N (`130` = SIGINT, `137` = SIGKILL, `143` = SIGTERM) | Shell |
| `255` | Argumento de `exit` fuera de rango, o "todo falló" por convención | Shell |
| `64`–`78` | Convenciones de `sysexits.h` (`EX_USAGE`=64 … `EX_CONFIG`=78) | Convención BSD, usada por los MTAs |

```
$ nosuchcommand; echo $?
bash: nosuchcommand: command not found
127

$ sh -c 'kill -TERM $$'; echo $?
143

$ sh -c 'exit 300'; echo $?
44
```

`exit 300` se envuelve módulo 256 → 44. **Nunca calcules un código de salida a partir de un conteo** (`exit "$errors"`); 256 errores se convierte en éxito.

### 4.2 Leer el status

`$?` contiene el status del **pipeline en primer plano completado más recientemente**. Es destruido por el comando siguiente, incluido `echo`.

```
$ grep -q root /etc/passwd
$ echo $?
0
$ echo $?
0        # <- this is the status of the previous echo, not of grep
```

Capturalo de inmediato si lo necesitás dos veces:

```sh
some_command
rc=$?
if [ "$rc" -ne 0 ]; then
    printf 'some_command failed with rc=%d\n' "$rc" >&2
fi
```

### 4.3 `&&`, `||`, `;` y control de flujo por cortocircuito

| Operador | Semántica | Exit status de la lista |
|---|---|---|
| `A ; B` | Ejecuta A, luego B incondicionalmente | Status de B |
| `A && B` | Ejecuta B solo si A devolvió 0 | Status del último comando ejecutado |
| `A \|\| B` | Ejecuta B solo si A devolvió distinto de cero | Status del último comando ejecutado |
| `A & B` | A en segundo plano, B inmediatamente | Status de B (el de A vía `wait`) |
| `A \| B` | stdout de A hacia stdin de B | Status de **B solamente**, salvo con `pipefail` |

El idiom clásico que espera el examen:

```sh
mkdir -p /var/lib/artifacts || exit 1
cd /var/lib/artifacts || exit 1
command -v rsync >/dev/null 2>&1 && rsync -a src/ dst/
```

`cd "$dir" || exit` no es estilístico. Sin eso, un `cd` fallido te deja en el directorio anterior y el `rm -rf ./*` siguiente borra el árbol equivocado. ShellCheck lo marca como **SC2164**.

### 4.4 La trampa del status del pipeline

```
$ false | true; echo $?
0

$ set -o pipefail
$ false | true; echo $?
1
$ set +o pipefail

$ false | true | false | true
$ echo "${PIPESTATUS[@]}"
1 0 1 0
```

`pipefail` y `PIPESTATUS` son **solo de bash/ksh/zsh** (`pipefail` fue estandarizado en POSIX Issue 8, 2024, pero dash no lo implementa). En un script `#!/bin/sh` tenés que reestructurar:

```sh
# Non-portable but correct in bash:
set -o pipefail
curl -fsS "$url" | tar -xzf - -C "$dest"

# Portable equivalent: stage it, check each stage.
tmp=$(mktemp) || exit 1
trap 'rm -f "$tmp"' EXIT INT TERM HUP
curl -fsS "$url" -o "$tmp" || exit 1
tar -xzf "$tmp" -C "$dest" || exit 1
```

Notá `curl -f`: sin eso, curl escribe una página de error HTTP 500 al archivo y sale con 0. `-fsS` = fallar ante errores HTTP, progreso silencioso, pero seguir mostrando errores. Es la misma clase de bug a nivel de herramienta.

### 4.5 Opciones de `set` — la tabla del modo estricto

| Opción | Forma larga | Efecto | POSIX | Advertencia |
|---|---|---|---|---|
| `-e` | `errexit` | Salir ante cualquier status distinto de cero no comprobado | ✓ | Muchas excepciones — ver abajo |
| `-u` | `nounset` | Error al expandir una variable no definida | ✓ | `"$@"` sin argumentos es seguro; `$1` no |
| `-x` | `xtrace` | Imprime cada comando después de la expansión | ✓ | Filtra secretos a los logs |
| `-v` | `verbose` | Imprime cada línea a medida que la lee | ✓ | Combina con `-n` para parsear |
| `-n` | `noexec` | Parsea pero no ejecuta | ✓ | Solo chequeo de sintaxis |
| `-f` | `noglob` | Deshabilita la expansión de rutas | ✓ | Útil alrededor de datos no confiables |
| `-C` | `noclobber` | `>` se niega a sobrescribir | ✓ | `>|` lo anula |
| `-o pipefail` | — | El pipeline falla si falla alguna etapa | Issue 8 | No está en dash |
| `-m` | `monitor` | Control de trabajos | ✓ | Desactivado en shells no interactivos |

`set -e` **no** se dispara en estas posiciones, y esta es la razón número uno por la que la gente cree que está roto:

```sh
set -e

# 1. Anything in a condition context — the whole point is to test it.
if failing_command; then :; fi          # no exit
while failing_command; do :; done       # no exit
failing_command && echo ok              # no exit
! failing_command                       # no exit

# 2. Any command but the last in an && / || list.
false && true                           # no exit

# 3. Any pipeline stage but the last (without pipefail).
false | true                            # no exit

# 4. THE KILLER: local/declare/export swallow the substitution status.
main() {
    local out=$(false)                  # rc of `local` is 0 -> no exit
    echo "still here"
}
```

El arreglo para #4 — ShellCheck **SC2155** — es separar la declaración de la asignación:

```sh
main() {
    local out
    out=$(false) || return 1
    printf '%s\n' "$out"
}
```

Encabezado recomendado para un script bash, y su hermano portable:

```sh
#!/bin/bash
set -Eeuo pipefail
IFS=$'\n\t'
```

```sh
#!/bin/sh
set -eu
```

`-E` (bash) hace que `trap ... ERR` se herede en funciones, subshells y sustituciones de comandos. `IFS=$'\n\t'` quita el espacio del separador de campos para que la división accidental en palabras por espacios deje de destrozar rutas en silencio — es un bashism (comillas ANSI-C `$'...'`) pero valioso.

---

## 5. `test`, `[` y condicionales

`test` y `[` son el mismo programa — y ambos son builtins del shell en todo shell moderno, con `/usr/bin/[` existiendo solo como respaldo.

```
$ type [ test
[ is a shell builtin
test is a shell builtin
$ ls -l /usr/bin/[ /usr/bin/test
-rwxr-xr-x. 1 root root 63704 Mar  4 12:01 /usr/bin/[
-rwxr-xr-x. 1 root root 59608 Mar  4 12:01 /usr/bin/test
```

`[` requiere un `]` literal como su último argumento. Por eso `[ "$a" = "$b" ]` necesita los espacios: son separadores de argumentos, no azúcar sintáctica.

### 5.1 Referencia de operadores

**Tests de archivo**

| Test | Verdadero cuando |
|---|---|
| `-e f` | `f` existe (de cualquier tipo) |
| `-f f` | Existe y es un archivo regular |
| `-d f` | Existe y es un directorio |
| `-L f` / `-h f` | Es un enlace simbólico (sin dereferenciar) |
| `-b f` / `-c f` | Dispositivo de bloque / de caracteres |
| `-p f` | Named pipe (FIFO) |
| `-S f` | Socket |
| `-r f` / `-w f` / `-x f` | Legible / escribible / ejecutable **por el UID efectivo** |
| `-s f` | Existe y su tamaño > 0 |
| `-u f` / `-g f` / `-k f` | Bit setuid / setgid / sticky activo |
| `-O f` / `-G f` | Propiedad del UID / GID efectivo |
| `-N f` | Modificado desde la última lectura (bash) |
| `f1 -nt f2` / `f1 -ot f2` | Más nuevo que / más viejo que (mtime) |
| `f1 -ef f2` | Mismo dispositivo e inodo (hard link o el mismo archivo) |

**Tests de cadena**

| Test | Verdadero cuando |
|---|---|
| `-z "$s"` | La longitud es cero |
| `-n "$s"` | La longitud es distinta de cero |
| `"$a" = "$b"` | Iguales (POSIX) |
| `"$a" != "$b"` | Distintos |
| `"$a" < "$b"` | Ordena antes, en el locale actual (`[[ ]]` de bash; en `[ ]` necesita escaparse) |

**Tests de enteros** — `-eq -ne -lt -le -gt -ge`. Son solo para enteros; `[ "$a" -eq "$b" ]` con un `$a` no numérico produce un error.

**Lógica** — `!` negación, `-a` AND, `-o` OR, `\( \)` agrupamiento. **No uses `-a`/`-o`**: están marcados como obsolescentes en POSIX y son ambiguos cuando los operandos parecen operadores. Usá operadores a nivel de shell en su lugar:

```sh
# Fragile
[ -f "$f" -a -r "$f" ]

# Correct
[ -f "$f" ] && [ -r "$f" ]
```

### 5.2 La regla de comillas que previene el 90% de los bugs de test

```
$ unset name
$ [ $name = "root" ] && echo match
bash: [: =: unary operator expected

$ [ "$name" = "root" ] && echo match
$ echo $?
1
```

Sin comillas, una variable vacía se expande a *nada*, y `[` recibe `= root ]` — tres argumentos donde esperaba cuatro. Poné comillas siempre. El histórico prefijo `x` (`[ "x$name" = "xroot" ]`) ya no es necesario con ningún `test` conforme a POSIX y solo oscurece la intención.

### 5.3 `[[ ]]` — qué te da y qué te cuesta (solo bash)

| Característica | `[ ]` | `[[ ]]` |
|---|---|---|
| División en palabras de variables sin comillas | Sí (peligroso) | No |
| Glob del lado derecho | No | `[[ $f == *.log ]]` |
| Regex | No | `[[ $s =~ ^v[0-9]+\.[0-9]+$ ]]`, grupos en `${BASH_REMATCH[@]}` |
| `&&` / `\|\|` adentro | No | Sí |
| Portabilidad | Universal | solo bash/ksh/zsh |

```
$ ver="v1.24"
$ [[ $ver =~ ^v([0-9]+)\.([0-9]+)$ ]] && echo "major=${BASH_REMATCH[1]} minor=${BASH_REMATCH[2]}"
major=1 minor=24
```

No pongas la regex entre comillas — hacerlo la convierte en una comparación literal de cadena.

### 5.4 Formas condicionales completas

```sh
if [ -f "$config" ]; then
    . "$config"
elif [ -f "$HOME/.config/app/config" ]; then
    . "$HOME/.config/app/config"
else
    printf 'no configuration found\n' >&2
    exit 78          # EX_CONFIG
fi

case "$1" in
    start|restart)  do_start ;;
    stop)           do_stop ;;
    status)         do_status ;;
    -h|--help)      usage; exit 0 ;;
    '')             usage >&2; exit 64 ;;   # EX_USAGE
    *)              printf 'unknown action: %s\n' "$1" >&2; exit 64 ;;
esac
```

`case` es POSIX, más rápido que una cadena de `if`, y hace coincidencia por glob sin invocar `test`. Es la herramienta correcta para el despacho de argumentos y para el manejo de verbos al estilo de los scripts de init.

---

## 6. Bucles e iteración segura

### 6.1 `for`

```sh
# POSIX: iterate over words
for env in dev staging prod; do
    printf 'deploying to %s\n' "$env"
done

# Over positional parameters — the quoted "$@" is mandatory
for arg in "$@"; do
    process "$arg"
done

# Bare `for arg; do` implicitly means "in \"$@\"" — POSIX and idiomatic
for arg; do
    process "$arg"
done
```

**Iterar sobre archivos — las cuatro opciones y sus compromisos:**

| Técnica | Maneja espacios | Maneja saltos de línea en los nombres | Recursivo | POSIX |
|---|---|---|---|---|
| `for f in *.log` | ✓ (la salida del glob no se divide en palabras) | ✓ | ✗ | ✓ |
| `for f in $(ls)` | ✗ | ✗ | ✗ | ✓ — **nunca hagas esto** (SC2045) |
| `find ... -exec cmd {} +` | ✓ | ✓ | ✓ | ✓ |
| `find -print0 \| while IFS= read -r -d ''` | ✓ | ✓ | ✓ | ✗ (`-d` es de bash) |

```sh
# Portable and safe:
find /var/log/app -type f -name '*.log' -mtime +30 -exec gzip -9 {} +

# Bash, when you need shell logic per file:
while IFS= read -r -d '' f; do
    [ -s "$f" ] || continue
    process "$f"
done < <(find /var/log/app -type f -name '*.log' -print0)
```

Prestá atención al caso del glob sin coincidencias. En `sh` POSIX, `for f in *.log` sin coincidencias itera una vez con `f` puesto a la cadena literal `*.log`:

```
$ cd /tmp/empty
$ for f in *.log; do echo "got: $f"; done
got: *.log
```
Protegelo: `[ -e "$f" ] || continue`. En bash, `shopt -s nullglob` hace que la lista quede vacía en su lugar — un bashism, pero uno correcto.

### 6.2 Bucles numéricos: `seq` vs expansión de llaves vs estilo C

| Forma | Shell | Notas |
|---|---|---|
| `for i in $(seq 1 10)` | POSIX + `seq` de coreutils | Forkea un proceso; en algunos builds de BusyBox no viene por defecto |
| `for i in $(seq 1 2 9)` | Igual | Forma con paso: inicio, incremento, fin |
| `for i in {1..10}` | bash / zsh | Sin fork; **no expande variables** — `{1..$n}` falla |
| `for ((i=1; i<=n; i++))` | bash | Sin fork, las variables funcionan; la elección correcta en bash |
| `i=1; while [ "$i" -le 10 ]; do ...; i=$((i+1)); done` | POSIX | Sin fork, sin dependencia externa |

```
$ seq -w 1 3
1
2
3
$ seq -s, 1 5
1,2,3,4,5
$ seq -f 'node-%02g' 1 3
node-01
node-02
node-03
```

`seq -f` es genuinamente útil para generar nombres de host y nombres de réplicas. Para rangos grandes, la forma `while` POSIX le gana a `seq` porque evita materializar la lista entera en memoria y evita un fork.

### 6.3 `while`, `until` y `read`

`while` itera según el exit status de una **lista de comandos**, no de un booleano. Por eso funciona el idiom de leer un archivo:

```sh
while IFS= read -r line; do
    case "$line" in
        ''|'#'*) continue ;;     # skip blanks and comments
    esac
    printf 'line: %s\n' "$line"
done < /etc/app/hosts.conf
```

Tres detalles, todos obligatorios:

* **`IFS=`** (vacío) evita el recorte de espacios en blanco iniciales/finales.
* **`-r`** evita que `read` interprete las barras invertidas como escapes.
* **`< file` después de `done`** redirige la stdin del bucle. Usar `cat file | while ...` en su lugar crea un subshell en `sh` POSIX y en bash, así que cualquier variable asignada dentro del bucle se pierde cuando termina.

```
$ count=0
$ printf 'a\nb\nc\n' | while read -r l; do count=$((count+1)); done
$ echo "$count"
0                       # <- the subshell's increment was discarded

$ count=0
$ while read -r l; do count=$((count+1)); done < <(printf 'a\nb\nc\n')
$ echo "$count"
3
```

El arreglo portable sin sustitución de procesos es la redirección desde un archivo, o un here-document:

```sh
count=0
while read -r l; do count=$((count+1)); done <<EOF
$(printf 'a\nb\nc\n')
EOF
echo "$count"   # 3
```

Un archivo sin salto de línea final pierde su última línea — `read` devuelve distinto de cero al llegar a EOF aunque haya asignado datos. La forma robusta:

```sh
while IFS= read -r line || [ -n "$line" ]; do
    handle "$line"
done < "$file"
```

**Reintento con backoff**, el `until` canónico de la ingeniería de plataforma:

```sh
attempt=0
max=5
delay=1
until curl -fsS -o /dev/null "http://localhost:8080/healthz"; do
    attempt=$((attempt + 1))
    if [ "$attempt" -ge "$max" ]; then
        printf 'health check failed after %d attempts\n' "$max" >&2
        exit 1
    fi
    sleep "$delay"
    delay=$((delay * 2))
done
printf 'healthy after %d retries\n' "$attempt"
```

`break` sale del bucle más interno, `continue` salta a la siguiente iteración; ambos aceptan un nivel numérico (`break 2`) para escapar de bucles anidados.

### 6.4 Opciones de `read`

| Opción | Significado | POSIX |
|---|---|---|
| `-r` | Raw — no tratar `\` como escape | ✓ |
| `-p 'prompt'` | Imprime el prompt en stderr primero | ✗ bash |
| `-s` | Silencioso (sin eco) — contraseñas | ✗ bash |
| `-t N` | Timeout después de N segundos | ✗ bash |
| `-n N` / `-N N` | Leer N caracteres | ✗ bash |
| `-d C` | Usar C como delimitador en vez del salto de línea | ✗ bash |
| `-a arr` | Leer palabras hacia un array | ✗ bash |
| `var1 var2 rest` | Divide según `IFS`; la última variable absorbe el resto | ✓ |

```
$ echo "web01 10.0.1.5 amd64 extra fields here" | \
  while read -r host ip arch rest; do
      printf 'host=%s ip=%s arch=%s rest=[%s]\n' "$host" "$ip" "$arch" "$rest"
  done
host=web01 ip=10.0.1.5 arch=amd64 rest=[extra fields here]
```

Prompt interactivo, forma portable:

```sh
printf 'Proceed with destructive rollout? [y/N] ' >&2
read -r answer
case "$answer" in
    [yY]|[yY][eE][sS]) ;;
    *) printf 'aborted\n' >&2; exit 1 ;;
esac
```

Siempre mostrá el prompt en **stderr**, para que el script siga siendo canalizable por pipe.

---

## 7. Sustitución de comandos

Dos sintaxis; solo una es aceptable en código nuevo.

| Forma | Anidamiento | Manejo de barras invertidas | Veredicto |
|---|---|---|---|
| `$(cmd)` | Trivial: `$(a $(b))` | Predecible | **Usá esta** |
| `` `cmd` `` | Requiere escapes: `` `a \`b\`` `` | `\` se trata de forma especial adentro | Solo legado (SC2006) |

Ambas son POSIX. Ambas **eliminan todos los saltos de línea finales** de la salida.

```
$ printf 'value\n\n\n' > /tmp/v
$ x=$(cat /tmp/v); printf '[%s]\n' "$x"
[value]
```

Para preservar los saltos de línea finales, agregá un centinela y quitalo:

```sh
x=$(cat /tmp/v; printf 'x')
x=${x%x}
```

### 7.1 Comillas en las sustituciones

```
$ mkdir -p '/tmp/my reports'
$ d=$(printf '/tmp/my reports')

$ ls $d
ls: cannot access '/tmp/my': No such file or directory
ls: cannot access 'reports': No such file or directory

$ ls "$d"
$ echo $?
0
```

Sin comillas, el resultado queda sujeto a división en palabras **y** a globbing. ShellCheck **SC2046** (`$(...)` sin comillas) y **SC2086** (`$var` sin comillas) existen exactamente por esto.

La única excepción intencional es cuando *querés* la división en argumentos — e incluso entonces, preferí el control explícito:

```sh
# Deliberate splitting, with the field separator pinned:
oldifs=$IFS
IFS=:
set -- $PATH
IFS=$oldifs
for dir; do printf 'PATH entry: %s\n' "$dir"; done
```

### 7.2 Sustitución aritmética vs de comandos

```
$ n=$(( 3 * 7 ))          # arithmetic expansion — POSIX, no fork
$ echo "$n"
21
$ files=$(ls -1 /etc | wc -l)   # command substitution — forks
$ echo "$files"
243
```

`$(( ))` es aritmética; `$( )` ejecuta un comando. Dentro de `$(( ))`, las variables no necesitan `$` (`$((n+1))` funciona). La forma de sentencia `(( ))` de bash *no* es POSIX y tiene una trampa de inversión del exit status: `(( 0 ))` devuelve 1, así que `set -e` matará un script en `((count++))` cuando `count` valía 0.

### 7.3 Patrones prácticos de sustitución

```
$ ts=$(date -u +%Y-%m-%dT%H:%M:%SZ); echo "$ts"
2026-08-26T11:42:07Z

$ nodes=$(kubectl get nodes -o jsonpath='{.items[*].metadata.name}')
$ for n in $nodes; do printf 'node: %s\n' "$n"; done
node: cp-01
node: worker-01
node: worker-02

$ if ! bin=$(command -v jq); then printf 'jq missing\n' >&2; exit 127; fi
$ echo "$bin"
/usr/bin/jq

$ mem_kb=$(awk '/^MemAvailable:/ {print $2}' /proc/meminfo)
$ [ "$mem_kb" -lt 524288 ] && printf 'WARNING: low memory (%s kB)\n' "$mem_kb"
```

Usá `command -v`, no `which`. `which` es un binario externo, no está en POSIX, está ausente de muchas imágenes mínimas, y devuelve 0 en algunas implementaciones incluso cuando no encontró nada.

---

## 8. Funciones, alcance y sourcing

### 8.1 Definición y retorno

```sh
# POSIX form — the only portable one
log() {
    printf '%s [%s] %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$1" "$2" >&2
}

die() {
    log ERROR "$*"
    exit 1
}

require_cmd() {
    for c in "$@"; do
        command -v "$c" >/dev/null 2>&1 || die "required command not found: $c"
    done
}
```

Dentro de una función, `$1 $2 … $@ $#` son los argumentos **de la función**, no los del script. `$0` sigue siendo el nombre del script. `return N` establece el exit status de la función; `return` sin argumento devuelve el status del último comando. `exit` termina el shell entero — una función que llama a `exit` no puede reutilizarse en una condición.

```
$ is_running() { systemctl is-active --quiet "$1"; }
$ is_running sshd && echo up || echo down
up
$ is_running nosuch.service; echo $?
4
```

El status pasa directo, que es exactamente lo que hace a las funciones componibles con `&&`, `||` e `if`.

**Devolver un valor, no un status:** las funciones de shell solo pueden devolver un status entero. Para devolver datos, imprimilos y capturalos:

```sh
current_release() {
    kubectl get deploy "$1" -o jsonpath='{.metadata.labels.release}' 2>/dev/null
}

rel=$(current_release checkout-api) || die "cannot read release"
[ -n "$rel" ] || die "deployment has no release label"
```

### 8.2 Alcance

```
$ f() { x=inside; }
$ x=outside; f; echo "$x"
inside

$ g() { local x=inside; }
$ x=outside; g; echo "$x"
outside
```

Todas las variables de shell son globales por defecto. `local` no está en POSIX-2018 pero está implementado por bash, dash, ash, ksh93 y zsh — es seguro usarlo en la práctica y es disciplina obligatoria en cualquier cosa de más de 50 líneas. Acordate de SC2155: `local x=$(cmd)` descarta el exit status de `cmd`.

### 8.3 `.` (punto) y `source`

`.` es POSIX; `source` es un sinónimo de bash. Ambos ejecutan el archivo **en el shell actual**, así que las variables, funciones y `cd` persisten.

| | `. ./lib.sh` | `./lib.sh` (exec) |
|---|---|---|
| Proceso | Shell actual | Proceso hijo |
| Variables asignadas | Persisten | Se descartan |
| `exit` adentro | Termina tu shell | Termina solo el hijo |
| Requiere bit de ejecución | No (con lectura alcanza) | Sí |
| Requiere shebang | No | Sí |

**Trampa de PATH:** el `.` de POSIX busca en `PATH` cuando el operando no contiene barras. `. lib.sh` puede hacer source de un archivo completamente distinto desde algún lugar del `PATH`. Escribí siempre `. ./lib.sh` o `. /usr/local/lib/app/lib.sh`.

Disposición estándar de biblioteca para un toolkit de plataforma:

```sh
#!/bin/sh
# /usr/local/bin/artifact-gc
set -eu

LIB_DIR=${LIB_DIR:-/usr/local/lib/platform}
# shellcheck source=/dev/null
. "$LIB_DIR/log.sh"
# shellcheck source=/dev/null
. "$LIB_DIR/retry.sh"
```

La directiva `# shellcheck source=` es obligatoria, o ShellCheck emite SC1091 para archivos que no puede resolver estáticamente.

`exec` reemplaza por completo el proceso del shell — sin fork, mismo PID:

```sh
exec >>/var/log/app/job.log 2>&1     # redirect the rest of the script
exec 3< /etc/app/hosts               # open fd 3 for reading
exec "$@"                            # hand off PID 1 to the real program
```

Esa última línea es la línea más importante de cualquier entrypoint de contenedor; la sección 12.3 explica por qué.

---

## 9. Argumentos, opciones y validación de entrada

### 9.1 Parámetros especiales

| Parámetro | Significado |
|---|---|
| `$0` | Nombre del script tal como fue invocado |
| `$1`…`$9`, `${10}` | Parámetros posicionales |
| `$#` | Cantidad de parámetros posicionales |
| `"$@"` | Todos los parámetros, **cada uno como una palabra separada** |
| `"$*"` | Todos los parámetros unidos por el primer carácter de `IFS` en **una sola palabra** |
| `$?` | Exit status del último pipeline en primer plano |
| `$$` | PID del shell |
| `$!` | PID del último comando en segundo plano |
| `$-` | Flags de opciones actuales |

`"$@"` y `"$*"` no son intercambiables. Con los argumentos `a b` y `c`:

```
$ set -- "a b" "c"
$ printf '[%s]\n' "$@"
[a b]
[c]
$ printf '[%s]\n' "$*"
[a b c]
$ printf '[%s]\n' $@
[a]
[b]
[c]
```

Regla: **`"$@"` siempre, en todos lados**, salvo que quieras específicamente una única cadena unida para un mensaje de log.

### 9.2 Expansión de parámetros para valores por defecto y validación

| Expansión | Comportamiento |
|---|---|
| `${var:-default}` | Usa `default` si no está definida **o está vacía** |
| `${var-default}` | Usa `default` solo si no está definida |
| `${var:=default}` | Asigna `default` si no está definida/está vacía (falla con parámetros posicionales) |
| `${var:?message}` | Error y sale del shell no interactivo si no está definida/está vacía |
| `${var:+alt}` | Usa `alt` solo si var está definida y no vacía |
| `${#var}` | Longitud |
| `${var#pat}` / `${var##pat}` | Quita el prefijo más corto / más largo |
| `${var%pat}` / `${var%%pat}` | Quita el sufijo más corto / más largo |

```
$ f=/var/log/app/checkout-api.access.log
$ echo "${f##*/}"
checkout-api.access.log
$ echo "${f%/*}"
/var/log/app
$ echo "${f%%.*}"
/var/log/app/checkout-api
$ echo "${f##*.}"
log
```

Estas son POSIX y reemplazan a `basename`/`dirname` sin forkear — algo significativo dentro de un bucle sobre 100 000 archivos.

```
$ sh -c ': "${DEPLOY_ENV:?must be set}"'
sh: 1: DEPLOY_ENV: must be set
$ echo $?
2
```

### 9.3 `getopts` — parseo de opciones POSIX

```sh
#!/bin/sh
set -eu

usage() {
    cat >&2 <<'EOF'
Usage: artifact-gc [-n] [-d DAYS] [-p PATH] [-v]
  -n        dry run; report what would be removed
  -d DAYS   remove artifacts older than DAYS (default: 30)
  -p PATH   artifact root (default: /var/lib/artifacts)
  -v        verbose
EOF
}

dry_run=0
days=30
root=/var/lib/artifacts
verbose=0

while getopts ':nd:p:vh' opt; do
    case "$opt" in
        n) dry_run=1 ;;
        d) days=$OPTARG ;;
        p) root=$OPTARG ;;
        v) verbose=1 ;;
        h) usage; exit 0 ;;
        :) printf 'option -%s requires an argument\n' "$OPTARG" >&2; usage; exit 64 ;;
        \?) printf 'unknown option: -%s\n' "$OPTARG" >&2; usage; exit 64 ;;
    esac
done
shift $((OPTIND - 1))

# Validate before doing anything destructive.
case "$days" in
    ''|*[!0-9]*) printf 'invalid -d value: %s\n' "$days" >&2; exit 64 ;;
esac
[ -d "$root" ] || { printf 'not a directory: %s\n' "$root" >&2; exit 66; }   # EX_NOINPUT
```

El `:` inicial en `':nd:p:vh'` pone a `getopts` en modo de reporte de errores *silencioso*, que es lo que te permite emitir tus propios mensajes para `:` y `\?`. `shift $((OPTIND - 1))` deja los operandos que no son opciones en `"$@"`.

`getopts` maneja únicamente opciones cortas. Las opciones largas de GNU requieren `getopt(1)` de util-linux, que **no es portable** y debe usarse con `eval set -- "$(getopt ...)"` — aceptable en una flota solo-Linux, descalificante para una imagen distroless.

El idiom `case "$days" in ''|*[!0-9]*)` es la comprobación portable de enteros. No uses `[ "$days" -gt 0 ]` para validar — un valor no numérico produce un error de shell, no un rechazo limpio.

---

## 10. Envío condicional de correo al superusuario

Este es un objetivo explícito de LPIC-1, y se corresponde directamente con la pregunta de producción: *¿cómo le avisa un trabajo batch a un humano que falló?*

### 10.1 El canal de cron (implícito, y el predeterminado)

cron envía por correo **cualquier salida** — stdout o stderr — de un trabajo al propietario, o a la dirección en `MAILTO`. Por eso el idiom universal de cron es "silencio ante el éxito":

```cron
MAILTO=root
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
SHELL=/bin/sh

# m h dom mon dow  command
17 3 * * *  /usr/local/sbin/artifact-gc -d 30 >/dev/null
```

`>/dev/null` descarta stdout; stderr queda intacto, así que solo los errores generan correo. `MAILTO=""` desactiva el correo por completo para ese crontab.

**Verificá el entorno del crontab, no lo asumas.** cron le da al trabajo un entorno mínimo — típicamente `PATH=/usr/bin:/bin`, sin `LANG`, con `HOME` tomado de `/etc/passwd`. Un script que funciona de forma interactiva y falla bajo cron es casi siempre un problema de `PATH`:

```
$ sudo crontab -l -u root
MAILTO=root
17 3 * * * /usr/local/sbin/artifact-gc -d 30 >/dev/null

$ sudo journalctl -t CRON --since '-1d' | tail -3
Aug 26 03:17:01 node01 CRON[41220]: (root) CMD (/usr/local/sbin/artifact-gc -d 30 >/dev/null)
Aug 26 03:17:01 node01 CRON[41219]: (root) MAIL (mailed 84 bytes of output but got status 0x0001 from MTA)
```

Esa segunda línea significa que el trabajo produjo salida y el MTA la rechazó — el camino de alerta en sí está roto.

### 10.2 El canal explícito

```sh
notify_root() {
    subject=$1
    shift
    if command -v mail >/dev/null 2>&1; then
        printf '%s\n' "$*" | mail -s "$subject" root
    elif command -v sendmail >/dev/null 2>&1; then
        {
            printf 'To: root\n'
            printf 'Subject: %s\n' "$subject"
            printf '\n%s\n' "$*"
        } | sendmail -t
    else
        logger -t artifact-gc -p cron.err -- "$subject: $*"
        return 1
    fi
}
```

Tené en cuenta que `mail`/`mailx` es provisto por al menos tres paquetes mutuamente incompatibles:

| Implementación | Paquete | `-a` significa | Notas |
|---|---|---|---|
| GNU Mailutils | `mailutils` | adjuntar archivo | `-A` también adjunta |
| bsd-mailx | `bsd-mailx` | adjuntar archivo (reciente) / agregar cabecera (más viejo) | Alternativa por defecto de Debian |
| s-nail / Heirloom | `s-nail`, `heirloom-mailx` | adjuntar (`s-nail`), cabecera (Heirloom) | `-S` fija opciones internas |

Nunca construyas automatización sobre `mail -a` sin revisar `man mail` en la imagen destino. `sendmail -t` (con el destinatario en las cabeceras del mensaje) es la interfaz más portable, porque todo MTA — Postfix, exim, msmtp, ssmtp, nullmailer — provee un binario compatible con `sendmail` en `/usr/sbin/sendmail`.

### 10.3 El script completo de correo condicional

```sh
#!/bin/sh
#
# /usr/local/sbin/artifact-gc
# Remove build artifacts older than N days. Mails root ONLY on failure.
# Exit codes: 0 ok | 1 gc failure | 64 usage | 66 bad input path | 75 lock held
#
set -eu

PROG=${0##*/}
ROOT=${ARTIFACT_ROOT:-/var/lib/artifacts}
DAYS=${ARTIFACT_MAX_AGE_DAYS:-30}
LOCK=/run/lock/${PROG}.lock
MAILTO=${MAILTO:-root}
HOSTNAME=$(uname -n)

log()  { printf '%s %s: %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$PROG" "$*" >&2; }
die()  { log "FATAL: $*"; exit "${2:-1}"; }

notify_root() {
    _subject=$1
    _body=$2
    if command -v sendmail >/dev/null 2>&1; then
        {
            printf 'To: %s\n' "$MAILTO"
            printf 'Subject: [%s] %s\n' "$HOSTNAME" "$_subject"
            printf 'X-Automation: %s\n' "$PROG"
            printf '\n%s\n' "$_body"
        } | /usr/sbin/sendmail -t
    elif command -v mail >/dev/null 2>&1; then
        printf '%s\n' "$_body" | mail -s "[$HOSTNAME] $_subject" "$MAILTO"
    else
        logger -t "$PROG" -p cron.err -- "$_subject"
        return 1
    fi
}

# Serialise: a second instance must not race the first.
if command -v flock >/dev/null 2>&1; then
    exec 9>"$LOCK" || die "cannot open lock file $LOCK" 75
    flock -n 9 || die "another instance holds $LOCK" 75
fi

[ -d "$ROOT" ] || die "artifact root is not a directory: $ROOT" 66
case "$DAYS" in ''|*[!0-9]*) die "invalid retention: $DAYS" 64 ;; esac

workdir=$(mktemp -d) || die "mktemp failed"
trap 'rm -rf "$workdir"' EXIT INT TERM HUP

errlog=$workdir/stderr
before=$(du -sk "$ROOT" 2>/dev/null | awk '{print $1}')

set +e
find "$ROOT" -mindepth 1 -type f -mtime "+$DAYS" -delete 2>"$errlog"
rc=$?
set -e

after=$(du -sk "$ROOT" 2>/dev/null | awk '{print $1}')
freed=$(( before - after ))

if [ "$rc" -ne 0 ]; then
    notify_root "artifact-gc FAILED (rc=$rc)" \
"Host:      $HOSTNAME
Root:      $ROOT
Retention: ${DAYS}d
Exit code: $rc
Freed:     ${freed} kB (partial)

--- stderr ---
$(cat "$errlog")
--------------
Investigate with:
  journalctl -t $PROG --since '-1h'
  ls -la $ROOT"
    die "gc failed with rc=$rc" "$rc"
fi

log "ok: freed ${freed} kB under $ROOT (retention ${DAYS}d)"
exit 0
```

Puntos de diseño que vale la pena internalizar:

* `set +e` / `set -e` alrededor del único comando cuyo fallo debe ser **manejado** en lugar de fatal.
* stderr se captura a un archivo para poder reportarlo *y* enviarlo por correo; descartarlo dejaría la alerta sin contenido.
* `flock -n 9` sobre un descriptor de archivo abierto con `exec` — el lock se libera automáticamente cuando el proceso muere, incluso ante `SIGKILL`. Un lock basado en archivo PID no es equivalente.
* `trap ... EXIT INT TERM HUP` garantiza la limpieza de temporales en toda vía de salida excepto `SIGKILL`. Notá que `EXIT` solo alcanza en bash, pero listar las señales explícitamente es el hábito portable.
* Los códigos de salida están documentados arriba de todo y son estables — ese es el contrato que consumen cron, systemd y Kubernetes.

### 10.4 Comparación de transportes

| Mecanismo | Garantías | Latencia | Falla en silencio cuando | Usar para |
|---|---|---|---|---|
| Correo implícito de cron | Cualquier salida → correo | Por ejecución | No hay MTA instalado; `MAILTO` sin definir y el usuario no tiene buzón | Trabajos tradicionales de un solo host |
| `mail`/`sendmail` dentro del script | Controlás asunto/cuerpo | Por ejecución | La cola del MTA está trabada; no hay MTA en el contenedor | Batch a nivel de host |
| `logger` → syslog/journald | Estructurado, siempre disponible localmente | Inmediata | Nadie mira el log | Todo, como piso mínimo |
| `OnFailure=` de systemd | Se dispara ante el fallo de la unidad, incluidos OOM-kill y timeout | Inmediata | El `Type=` de la unidad está mal y el fallo nunca se detecta | Trabajos gestionados por systemd |
| Webhook (`curl` a alertmanager) | Enrutado, deduplicado, con escalado | Inmediata | Egreso de red bloqueado; sin reintento | Clústeres |
| Fallo de Job de Kubernetes + métrica `kube_job_failed` | Observado por Prometheus | Intervalo de scrape | El `backoffLimit` del Job se agota en silencio | Batch de clúster |

En un contenedor normalmente **no hay MTA alguno**, así que `mail` es un no-op. Los equivalentes correctos dentro del clúster son: salir con estado distinto de cero (para que el Job quede marcado como fallido), escribir a stderr (para que el recolector de logs lo capture) y opcionalmente hacer `curl` a un endpoint de Alertmanager. La sección 12 muestra las tres.

---

## 11. Dónde viven los scripts: FHS, propiedad y permisos

### 11.1 La tabla de ubicaciones

| Ruta | Propósito | Propietario:Grupo | Modo | Gestionado por |
|---|---|---|---|---|
| `/usr/local/bin` | Comandos escritos localmente para **todos los usuarios** | `root:root` | `0755` | Vos |
| `/usr/local/sbin` | Comandos escritos localmente **solo para root** | `root:root` | `0755` | Vos |
| `/usr/local/lib/<pkg>` | Bibliotecas para hacer source, no ejecutables directamente | `root:root` | `0644` | Vos |
| `/usr/bin`, `/usr/sbin` | Archivos de paquetes de la distribución | `root:root` | `0755` | Gestor de paquetes — **no tocar** |
| `/opt/<vendor>/bin` | Paquetes adicionales autocontenidos de terceros | vendor | `0755` | Instalador del proveedor |
| `~/bin`, `~/.local/bin` | Scripts por usuario | usuario | `0755` | El usuario; en el PATH vía `~/.profile` en la mayoría de las distros |
| `/etc/profile.d/*.sh` | Fragmentos de entorno para shells de login — **se hace source, no se ejecutan** | `root:root` | `0644` | Vos |
| `/etc/cron.{hourly,daily,weekly,monthly}` | Trabajos periódicos ejecutados por `run-parts` | `root:root` | `0755` | Vos |
| `/etc/cron.d/<name>` | Fragmentos en formato crontab (con campo de usuario) | `root:root` | `0644` | Vos |
| `/etc/init.d` | Scripts de init SysV (cabecera LSB requerida) | `root:root` | `0755` | Legado |
| `/etc/systemd/system` | Archivos de unidad locales y overrides | `root:root` | `0644` | Vos |
| `/usr/lib/systemd/system` | Archivos de unidad de la distribución | `root:root` | `0644` | Gestor de paquetes |
| `/etc/network/if-up.d`, `/etc/NetworkManager/dispatcher.d` | Hooks de eventos de red | `root:root` | `0755` | Vos |
| `/var/lib/<pkg>` | Estado variable — **nunca** pongas scripts acá | varía | varía | La app |

La regla del FHS que sustenta todo esto: **`/usr/local` está reservado para software instalado por el administrador local y nunca debe ser escrito por el gestor de paquetes**. Poner tu script en `/usr/bin` significa que el próximo `dnf upgrade` o `apt upgrade` puede sobrescribirlo o eliminarlo en silencio.

### 11.2 La trampa de nombres de `run-parts`

El `run-parts` de Debian, que impulsa `/etc/cron.daily`, **omite en silencio** cualquier nombre de archivo que no coincida con `^[a-zA-Z0-9_-]+$` a menos que se lo invoque con `--lsbsysinit`. Un archivo llamado `backup.sh` en `/etc/cron.daily` nunca se ejecuta, y nada registra una advertencia.

```
$ sudo install -m 0755 -o root -g root backup.sh /etc/cron.daily/backup.sh
$ run-parts --test /etc/cron.daily
/etc/cron.daily/apt-compat
/etc/cron.daily/logrotate
/etc/cron.daily/man-db
                                   # backup.sh is absent

$ sudo mv /etc/cron.daily/backup.sh /etc/cron.daily/backup
$ run-parts --test /etc/cron.daily
/etc/cron.daily/apt-compat
/etc/cron.daily/backup
/etc/cron.daily/logrotate
/etc/cron.daily/man-db
```

**Validá siempre con `run-parts --test` después de dejar un archivo en un directorio `cron.*`.** Los archivos también deben ser ejecutables y pertenecer a root; `run-parts` omite los no ejecutables y los que terminan en `.dpkg-dist`, `.dpkg-old`, `~`, `,`.

### 11.3 Instalación, propiedad y permisos

Usá `install(1)` en vez de `cp` + `chmod` + `chown` — es atómico en intención y fija los tres en una sola llamada:

```
$ sudo install -D -o root -g root -m 0755 artifact-gc /usr/local/sbin/artifact-gc
$ ls -l /usr/local/sbin/artifact-gc
-rwxr-xr-x. 1 root root 2314 Aug 26 11:58 /usr/local/sbin/artifact-gc

$ sudo install -D -o root -g root -m 0644 lib/log.sh /usr/local/lib/platform/log.sh
```

Notá que la biblioteca queda en `0644`, no `0755`. Un archivo que se hace source necesita lectura, no ejecución; hacerlo ejecutable invita a que alguien lo corra directamente.

Modelo de permisos para scripts:

| Modo | Significado | Cuándo |
|---|---|---|
| `0755` | Cualquiera puede leer y ejecutar; solo root puede modificar | Script de sistema normal en `/usr/local/bin` |
| `0750` | Ejecución restringida al grupo | Script para un grupo de operaciones específico; fijá el grupo en consecuencia |
| `0700` | Solo el propietario | Scripts que contienen credenciales embebidas (mejor: no embeber credenciales) |
| `0644` | Solo lectura, para hacer source | Bibliotecas, fragmentos de `/etc/profile.d` |

### 11.4 setuid en scripts — el filo del objetivo

LPIC-1 menciona los "derechos suid" en este objetivo, y la respuesta profesional correcta es:

> **El bit setuid no tiene efecto sobre los scripts de shell en Linux.** El kernel lo ignora deliberadamente para archivos interpretados con `#!` por una condición de carrera de exec imposible de arreglar, así que un script setuid no es una escalada de privilegios — es un no-op engañoso que será marcado por cualquier escáner de seguridad.

```
$ sudo install -m 4755 -o root -g root whoami-test.sh /usr/local/bin/whoami-test.sh
$ ls -l /usr/local/bin/whoami-test.sh
-rwsr-xr-x. 1 root root 40 Aug 26 12:03 /usr/local/bin/whoami-test.sh

$ cat /usr/local/bin/whoami-test.sh
#!/bin/sh
id -u

$ /usr/local/bin/whoami-test.sh
1000                       # <- still the calling user; setuid was ignored
```

Encontrarlos a lo largo de una flota:

```
$ sudo find / -xdev \( -perm -4000 -o -perm -2000 \) -type f -printf '%M %u %g %p\n' 2>/dev/null
-rwsr-xr-x root root /usr/bin/sudo
-rwsr-xr-x root root /usr/bin/passwd
-rwsr-xr-x root root /usr/bin/su
-rwxr-sr-x root shadow /usr/bin/chage
-rwsr-xr-x root root /usr/local/bin/whoami-test.sh     # <- remove this
```

El mecanismo correcto para privilegios delegados es `sudo` con una regla estrictamente acotada, validada con `visudo -c`:

```
# /etc/sudoers.d/artifact-gc  (mode 0440, root:root)
Cmnd_Alias ARTIFACT_GC = /usr/local/sbin/artifact-gc
%platform-ops ALL=(root) NOPASSWD: ARTIFACT_GC
```

```
$ sudo visudo -cf /etc/sudoers.d/artifact-gc
/etc/sudoers.d/artifact-gc: parsed OK
```

Dos requisitos de endurecimiento cuando un script es alcanzable a través de `sudo`:

1. Fijá `PATH` explícitamente al principio del script; no confíes en el heredado.
2. No aceptes ningún argumento que se interpole en un comando sin validación — `sudo artifact-gc -p '/; rm -rf /'` debe ser rechazado por el validador `case`, no ejecutado.

---

## 12. Artefactos de producción, completos y sin abreviar

### 12.1 Servicio + timer de systemd + correo ante fallo

Reemplazar cron por systemd te da ordenamiento de dependencias, límites de recursos, sandboxing, una señal de fallo real e integración con journald. Este es el conjunto completo.

`/etc/systemd/system/artifact-gc.service`:

```ini
[Unit]
Description=Garbage-collect build artifacts older than the retention window
Documentation=man:artifact-gc(8)
After=network-online.target local-fs.target
Wants=network-online.target
OnFailure=unit-failure-mail@%n.service
StartLimitIntervalSec=3600
StartLimitBurst=3

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/artifact-gc -d 30 -p /var/lib/artifacts
Environment=PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
Environment=LC_ALL=C
Environment=MAILTO=root
User=root
Group=root

# Failure semantics
TimeoutStartSec=900
SuccessExitStatus=0
Restart=no

# Sandboxing: the script needs only its artifact root.
ProtectSystem=strict
ProtectHome=yes
PrivateTmp=yes
PrivateDevices=yes
NoNewPrivileges=yes
ReadWritePaths=/var/lib/artifacts /run/lock
RestrictAddressFamilies=AF_UNIX
RestrictSUIDSGID=yes
LockPersonality=yes
MemoryMax=512M
CPUQuota=50%

# Observability
StandardOutput=journal
StandardError=journal
SyslogIdentifier=artifact-gc

[Install]
WantedBy=multi-user.target
```

`/etc/systemd/system/artifact-gc.timer`:

```ini
[Unit]
Description=Daily artifact garbage collection
Documentation=man:artifact-gc(8)

[Timer]
OnCalendar=*-*-* 03:17:00
RandomizedDelaySec=600
Persistent=true
AccuracySec=1min
Unit=artifact-gc.service

[Install]
WantedBy=timers.target
```

`RandomizedDelaySec` dispersa la flota para que 400 nodos no golpeen el almacenamiento compartido en el mismo segundo. `Persistent=true` ejecuta una ocurrencia perdida después de que el nodo arranca — la propiedad que a cron le falta.

`/etc/systemd/system/unit-failure-mail@.service`:

```ini
[Unit]
Description=Mail root about the failure of unit %i
After=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/unit-failure-mail %i
User=root
Group=root
```

`/usr/local/sbin/unit-failure-mail`:

```sh
#!/bin/sh
#
# Mail root a full post-mortem for a failed systemd unit.
# Invoked as: unit-failure-mail <unit-name>   (from OnFailure=unit-failure-mail@%n.service)
#
set -eu

unit=${1:?usage: unit-failure-mail <unit>}
host=$(uname -n)
to=${MAILTO:-root}

body=$(
    printf 'Unit %s failed on %s at %s\n\n' \
        "$unit" "$host" "$(date -u +%Y-%m-%dT%H:%M:%SZ)"

    printf '=== systemctl status ===\n'
    systemctl status --full --no-pager --lines=0 "$unit" 2>&1 || true

    printf '\n=== properties ===\n'
    systemctl show "$unit" \
        --property=Result,ExecMainStatus,ExecMainCode,NRestarts,ActiveEnterTimestamp \
        2>&1 || true

    printf '\n=== last 100 journal lines ===\n'
    journalctl --unit="$unit" --no-pager --lines=100 2>&1 || true
)

if command -v sendmail >/dev/null 2>&1; then
    {
        printf 'To: %s\n' "$to"
        printf 'Subject: [%s] systemd unit FAILED: %s\n' "$host" "$unit"
        printf 'Auto-Submitted: auto-generated\n'
        printf '\n%s\n' "$body"
    } | /usr/sbin/sendmail -t
elif command -v mail >/dev/null 2>&1; then
    printf '%s\n' "$body" | mail -s "[$host] systemd unit FAILED: $unit" "$to"
else
    printf '%s\n' "$body" | logger -t unit-failure-mail -p daemon.err
    exit 1
fi
```

Despliegue y verificación:

```
$ sudo install -D -o root -g root -m 0755 unit-failure-mail /usr/local/sbin/unit-failure-mail
$ sudo install -D -o root -g root -m 0644 artifact-gc.service /etc/systemd/system/artifact-gc.service
$ sudo install -D -o root -g root -m 0644 artifact-gc.timer   /etc/systemd/system/artifact-gc.timer
$ sudo install -D -o root -g root -m 0644 unit-failure-mail@.service /etc/systemd/system/unit-failure-mail@.service

$ sudo systemd-analyze verify /etc/systemd/system/artifact-gc.service
$ echo $?
0

$ sudo systemctl daemon-reload
$ sudo systemctl enable --now artifact-gc.timer
Created symlink /etc/systemd/system/timers.target.wants/artifact-gc.timer → /etc/systemd/system/artifact-gc.timer.

$ systemctl list-timers artifact-gc.timer
NEXT                        LEFT     LAST PASSED UNIT              ACTIVATES
Thu 2026-08-27 03:23:41 UTC 15h left n/a  n/a    artifact-gc.timer artifact-gc.service

$ sudo systemctl start artifact-gc.service
$ systemctl show artifact-gc.service -p Result -p ExecMainStatus
Result=success
ExecMainStatus=0

$ journalctl -u artifact-gc.service -n 3 --no-pager
Aug 26 12:14:02 node01 systemd[1]: Starting Garbage-collect build artifacts...
Aug 26 12:14:03 node01 artifact-gc[41883]: 2026-08-26T12:14:03Z artifact-gc: ok: freed 184320 kB under /var/lib/artifacts (retention 30d)
Aug 26 12:14:03 node01 systemd[1]: Finished Garbage-collect build artifacts.
```

Probá que el camino de fallo efectivamente se dispara — un camino de alerta no probado no es un camino de alerta:

```
$ sudo ARTIFACT_ROOT=/nonexistent systemd-run --unit=gc-failtest \
    --property=OnFailure=unit-failure-mail@gc-failtest.service \
    /usr/local/sbin/artifact-gc -p /nonexistent
Running as unit: gc-failtest.service

$ systemctl show gc-failtest.service -p Result -p ExecMainStatus
Result=exit-code
ExecMainStatus=66

$ journalctl -u unit-failure-mail@gc-failtest.service -n 2 --no-pager
Aug 26 12:16:41 node01 systemd[1]: Starting Mail root about the failure of unit gc-failtest.service...
Aug 26 12:16:42 node01 systemd[1]: Finished Mail root about the failure of unit gc-failtest.service.

$ sudo mail -H
>N  1 root  Wed Aug 26 12:16  38/1402  [node01] systemd unit FAILED: gc-failtest.service
```

### 12.2 Kubernetes: script entregado por ConfigMap + CronJob

Manifiesto completo, sin elisiones.

```yaml
---
apiVersion: v1
kind: Namespace
metadata:
  name: platform-jobs
  labels:
    pod-security.kubernetes.io/enforce: restricted
    pod-security.kubernetes.io/audit: restricted
    pod-security.kubernetes.io/warn: restricted
---
apiVersion: v1
kind: ServiceAccount
metadata:
  name: artifact-gc
  namespace: platform-jobs
automountServiceAccountToken: false
---
apiVersion: v1
kind: ConfigMap
metadata:
  name: artifact-gc-script
  namespace: platform-jobs
  labels:
    app.kubernetes.io/name: artifact-gc
    app.kubernetes.io/component: batch
data:
  artifact-gc.sh: |
    #!/bin/sh
    #
    # Artifact garbage collector, container edition.
    # No MTA exists in this image: the failure channel is (a) a non-zero exit,
    # which marks the Job failed and is scraped by kube-state-metrics, and
    # (b) structured stderr, which the log pipeline ingests.
    #
    # Exit codes: 0 ok | 1 gc failure | 64 usage | 66 bad root | 69 unavailable
    #
    set -eu

    PROG=artifact-gc
    ROOT=${ARTIFACT_ROOT:?ARTIFACT_ROOT must be set}
    DAYS=${ARTIFACT_MAX_AGE_DAYS:-30}
    ALERT_URL=${ALERTMANAGER_URL:-}
    NODE=${NODE_NAME:-unknown}
    POD=${POD_NAME:-unknown}

    log() {
        # One JSON object per line: parseable by any log pipeline.
        printf '{"ts":"%s","level":"%s","prog":"%s","pod":"%s","node":"%s","msg":"%s"}\n' \
            "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$1" "$PROG" "$POD" "$NODE" "$2" >&2
    }

    die() {
        log error "$1"
        [ -n "$ALERT_URL" ] && alert "$1"
        exit "${2:-1}"
    }

    alert() {
        command -v curl >/dev/null 2>&1 || return 0
        curl -fsS -m 10 -X POST -H 'Content-Type: application/json' \
             -d "[{\"labels\":{\"alertname\":\"ArtifactGCFailed\",\"severity\":\"warning\",\"pod\":\"$POD\",\"node\":\"$NODE\"},\"annotations\":{\"description\":\"$1\"}}]" \
             "$ALERT_URL/api/v2/alerts" >/dev/null 2>&1 || true
    }

    case "$DAYS" in
        ''|*[!0-9]*) die "invalid ARTIFACT_MAX_AGE_DAYS: $DAYS" 64 ;;
    esac
    [ -d "$ROOT" ] || die "artifact root is not a directory: $ROOT" 66

    workdir=$(mktemp -d) || die "mktemp failed" 69
    trap 'rm -rf "$workdir"' EXIT INT TERM HUP

    errlog=$workdir/stderr
    before=$(du -sk "$ROOT" 2>/dev/null | awk '{print $1+0}')

    log info "starting gc: root=$ROOT retention=${DAYS}d size=${before}kB"

    set +e
    find "$ROOT" -mindepth 1 -type f -mtime "+$DAYS" -delete 2>"$errlog"
    rc=$?
    set -e

    after=$(du -sk "$ROOT" 2>/dev/null | awk '{print $1+0}')
    freed=$(( before - after ))

    if [ "$rc" -ne 0 ]; then
        while IFS= read -r line; do log error "find: $line"; done < "$errlog"
        die "gc failed rc=$rc freed=${freed}kB" "$rc"
    fi

    # Prune now-empty directories, best effort.
    find "$ROOT" -mindepth 1 -type d -empty -delete 2>/dev/null || true

    log info "ok: freed ${freed}kB remaining=${after}kB"
    exit 0
---
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: artifacts
  namespace: platform-jobs
spec:
  accessModes:
    - ReadWriteMany
  resources:
    requests:
      storage: 200Gi
  storageClassName: nfs-csi
---
apiVersion: batch/v1
kind: CronJob
metadata:
  name: artifact-gc
  namespace: platform-jobs
  labels:
    app.kubernetes.io/name: artifact-gc
    app.kubernetes.io/component: batch
spec:
  schedule: "17 3 * * *"
  timeZone: "Etc/UTC"
  concurrencyPolicy: Forbid
  startingDeadlineSeconds: 300
  successfulJobsHistoryLimit: 3
  failedJobsHistoryLimit: 5
  suspend: false
  jobTemplate:
    spec:
      backoffLimit: 2
      activeDeadlineSeconds: 1800
      ttlSecondsAfterFinished: 86400
      template:
        metadata:
          labels:
            app.kubernetes.io/name: artifact-gc
          annotations:
            kubectl.kubernetes.io/default-container: gc
        spec:
          restartPolicy: Never
          serviceAccountName: artifact-gc
          automountServiceAccountToken: false
          terminationGracePeriodSeconds: 30
          securityContext:
            runAsNonRoot: true
            runAsUser: 65534
            runAsGroup: 65534
            fsGroup: 65534
            seccompProfile:
              type: RuntimeDefault
          containers:
            - name: gc
              image: busybox:1.36.1
              imagePullPolicy: IfNotPresent
              command:
                - /bin/sh
                - /scripts/artifact-gc.sh
              env:
                - name: ARTIFACT_ROOT
                  value: /artifacts
                - name: ARTIFACT_MAX_AGE_DAYS
                  value: "30"
                - name: ALERTMANAGER_URL
                  value: http://alertmanager.monitoring.svc.cluster.local:9093
                - name: NODE_NAME
                  valueFrom:
                    fieldRef:
                      fieldPath: spec.nodeName
                - name: POD_NAME
                  valueFrom:
                    fieldRef:
                      fieldPath: metadata.name
              securityContext:
                allowPrivilegeEscalation: false
                readOnlyRootFilesystem: true
                capabilities:
                  drop:
                    - ALL
              resources:
                requests:
                  cpu: 50m
                  memory: 64Mi
                limits:
                  cpu: 500m
                  memory: 256Mi
              volumeMounts:
                - name: scripts
                  mountPath: /scripts
                  readOnly: true
                - name: artifacts
                  mountPath: /artifacts
                - name: tmp
                  mountPath: /tmp
          volumes:
            - name: scripts
              configMap:
                name: artifact-gc-script
                defaultMode: 0555
            - name: artifacts
              persistentVolumeClaim:
                claimName: artifacts
            - name: tmp
              emptyDir:
                medium: Memory
                sizeLimit: 32Mi
```

Cuatro decisiones en ese manifiesto existen específicamente por la semántica del shell:

* **`command: ["/bin/sh", "/scripts/artifact-gc.sh"]`, no `["/scripts/artifact-gc.sh"]`.** Un montaje de volumen de ConfigMap es una granja de symlinks hacia `..data/`; `defaultMode: 0555` sí otorga ejecución, pero con `readOnlyRootFilesystem` y algunas configuraciones de CSI/montaje el bit de ejecución puede perderse. Invocar el intérprete explícitamente elimina por completo la dependencia del bit de modo — y vuelve irrelevante el shebang, que es por lo que el script debe ser `sh` POSIX: la imagen es BusyBox y `/bin/sh` es `ash`.
* **`ARTIFACT_ROOT=${ARTIFACT_ROOT:?...}`** convierte una variable de entorno ausente en un fallo inmediato y ruidoso, en lugar de que `find  -mindepth 1 -delete` corra contra el CWD.
* **`tmp` como `emptyDir`** porque `readOnlyRootFilesystem: true` hace que `mktemp` falle de otro modo — ese es el camino `69 EX_UNAVAILABLE`.
* **`concurrencyPolicy: Forbid`** es el reemplazo nativo de contenedores para `flock`. Sin eso, una ejecución lenta que se solape con la siguiente programación produce dos procesos borrando del mismo PVC.

Aplicar y verificar:

```
$ kubectl apply -f artifact-gc.yaml
namespace/platform-jobs created
serviceaccount/artifact-gc created
configmap/artifact-gc-script created
persistentvolumeclaim/artifacts created
cronjob.batch/artifact-gc created

$ kubectl -n platform-jobs get cronjob artifact-gc
NAME          SCHEDULE      TIMEZONE   SUSPEND   ACTIVE   LAST SCHEDULE   AGE
artifact-gc   17 3 * * *    Etc/UTC    False     0        <none>          12s

$ kubectl -n platform-jobs create job --from=cronjob/artifact-gc artifact-gc-manual-001
job.batch/artifact-gc-manual-001 created

$ kubectl -n platform-jobs wait --for=condition=complete job/artifact-gc-manual-001 --timeout=300s
job.batch/artifact-gc-manual-001 condition met

$ kubectl -n platform-jobs logs job/artifact-gc-manual-001
{"ts":"2026-08-26T12:31:08Z","level":"info","prog":"artifact-gc","pod":"artifact-gc-manual-001-x4k2n","node":"worker-02","msg":"starting gc: root=/artifacts retention=30d size=194580kB"}
{"ts":"2026-08-26T12:31:11Z","level":"info","prog":"artifact-gc","pod":"artifact-gc-manual-001-x4k2n","node":"worker-02","msg":"ok: freed 41220kB remaining=153360kB"}

$ kubectl -n platform-jobs get job artifact-gc-manual-001 -o jsonpath='{.status.succeeded}{"\n"}'
1
```

Y el camino de fallo, que debe ejercitarse deliberadamente:

```
$ kubectl -n platform-jobs create job gc-failtest \
    --from=cronjob/artifact-gc --dry-run=client -o yaml \
  | sed 's|value: /artifacts|value: /nonexistent|' \
  | kubectl apply -f -
job.batch/gc-failtest created

$ kubectl -n platform-jobs get pods -l job-name=gc-failtest
NAME                READY   STATUS   RESTARTS   AGE
gc-failtest-9dm7q   0/1     Error    0          14s

$ kubectl -n platform-jobs logs job/gc-failtest
{"ts":"2026-08-26T12:33:02Z","level":"error","prog":"artifact-gc","pod":"gc-failtest-9dm7q","node":"worker-01","msg":"artifact root is not a directory: /nonexistent"}

$ kubectl -n platform-jobs get pod gc-failtest-9dm7q \
    -o jsonpath='{.status.containerStatuses[0].state.terminated.exitCode}{"\n"}'
66
```

El código de salida 66 llega intacto al status del contenedor. Ese es todo el punto de la sección 4 hecho concreto: el entero del shell es la señal de control de la plataforma.

### 12.3 Entrypoint de contenedor: `exec` y PID 1

```sh
#!/bin/sh
#
# /entrypoint.sh — render config from the environment, then hand off to the app.
#
set -eu

: "${APP_PORT:=8080}"
: "${APP_LOG_LEVEL:=info}"
: "${DATABASE_URL:?DATABASE_URL must be set}"

CONF=/etc/app/config.yaml

log() { printf '{"ts":"%s","level":"%s","msg":"%s"}\n' \
        "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$1" "$2" >&2; }

# Refuse to start rather than start misconfigured.
case "$APP_PORT" in
    ''|*[!0-9]*) log error "APP_PORT is not numeric: $APP_PORT"; exit 78 ;;
esac
case "$APP_LOG_LEVEL" in
    debug|info|warn|error) ;;
    *) log error "invalid APP_LOG_LEVEL: $APP_LOG_LEVEL"; exit 78 ;;
esac

umask 0027
mkdir -p /var/run/app

cat > "$CONF" <<EOF
server:
  port: ${APP_PORT}
  shutdownGraceSeconds: 25
logging:
  level: ${APP_LOG_LEVEL}
  format: json
database:
  url: ${DATABASE_URL}
EOF

log info "config rendered at ${CONF}, starting: $*"

# CRITICAL: exec replaces this shell, so the application becomes PID 1 and
# receives SIGTERM directly from the container runtime. Without exec, the
# shell stays PID 1, ignores SIGTERM (non-interactive shells do not install
# a handler), and the pod is SIGKILLed after terminationGracePeriodSeconds.
exec "$@"
```

Probándolo, que es el tipo de comprobación que convierte una actualización progresiva de 30 segundos en una de 3:

```
$ docker run -d --name t1 --entrypoint /bin/sh myapp:1.4 -c '/usr/bin/app --serve'
9f2c1a...
$ docker exec t1 ps -o pid,comm
  PID COMMAND
    1 sh
    7 app
$ time docker stop t1
t1
real    0m10.284s          # <- SIGTERM ignored by the shell; SIGKILL after the timeout

$ docker run -d --name t2 --entrypoint /entrypoint.sh myapp:1.4 /usr/bin/app --serve
3a7e44...
$ docker exec t2 ps -o pid,comm
  PID COMMAND
    1 app
$ time docker stop t2
t2
real    0m0.412s
```

### 12.4 Compuerta de CI

`.github/workflows/shell-lint.yml`:

```yaml
name: shell-lint

on:
  push:
    branches: [main]
  pull_request:

permissions:
  contents: read

jobs:
  lint:
    runs-on: ubuntu-24.04
    steps:
      - name: Checkout
        uses: actions/checkout@v4

      - name: Install linters
        run: |
          set -euo pipefail
          sudo apt-get update -qq
          sudo apt-get install -y --no-install-recommends shellcheck devscripts dash bats

      - name: Discover shell scripts
        id: discover
        run: |
          set -euo pipefail
          # Anything with a shell shebang, plus *.sh, excluding vendored trees.
          find . -path ./.git -prune -o -type f -print0 \
            | xargs -0 -r file --mime-type \
            | awk -F': ' '$2 ~ /x-shellscript/ {print $1}' \
            | sort -u > /tmp/scripts.txt
          printf 'found %d scripts\n' "$(wc -l < /tmp/scripts.txt)"
          cat /tmp/scripts.txt

      - name: Syntax check with the declared interpreter
        run: |
          set -euo pipefail
          rc=0
          while IFS= read -r f; do
            shebang=$(head -n 1 "$f")
            case "$shebang" in
              *bash*) bash -n "$f" || rc=1 ;;
              *)      dash -n "$f" || rc=1 ;;   # /bin/sh scripts must parse under dash
            esac
          done < /tmp/scripts.txt
          exit "$rc"

      - name: ShellCheck
        run: |
          set -euo pipefail
          xargs -r -a /tmp/scripts.txt shellcheck \
            --severity=warning \
            --enable=all \
            --exclude=SC2312 \
            --format=gcc

      - name: checkbashisms on /bin/sh scripts
        run: |
          set -euo pipefail
          rc=0
          while IFS= read -r f; do
            case "$(head -n 1 "$f")" in
              */bin/sh|*"env sh") checkbashisms -f "$f" || rc=1 ;;
            esac
          done < /tmp/scripts.txt
          exit "$rc"

      - name: Unit tests
        run: bats -r tests/
```

Dos sutilezas que vale la pena copiar: `xargs -r` (no ejecutes el linter con cero argumentos, lo que haría que ShellCheck lea de stdin y se cuelgue), y correr `dash -n` contra los scripts `#!/bin/sh` para que el parser de CI sea el mismo que usará producción.

Un `.git/hooks/pre-commit` equivalente lo detecta antes y gratis:

```sh
#!/bin/sh
set -eu

fail=0
git diff --cached --name-only --diff-filter=ACM -z \
| while IFS= read -r -d '' f; do
    [ -f "$f" ] || continue
    case "$(file --mime-type -b -- "$f")" in
        text/x-shellscript) ;;
        *) continue ;;
    esac
    shellcheck --severity=warning -- "$f" || fail=1
    case "$(head -n 1 -- "$f")" in
        */bin/sh) dash -n -- "$f" || fail=1 ;;
        *bash)    bash -n -- "$f" || fail=1 ;;
    esac
done

exit "$fail"
```

---

## 13. Verificación y diagnóstico de fallos

### 13.1 La escalera de verificación

Ejecutá esto en orden. Cada escalón es más barato que el siguiente, y cada uno atrapa una clase que el anterior no puede.

| Escalón | Comando | Detecta | Costo |
|---|---|---|---|
| 0 | `head -c 2 f \| xxd` / `file f` | Shebang ausente, CRLF, tipo de archivo incorrecto | Instantáneo |
| 1 | `sh -n f` / `bash -n f` | Errores de sintaxis, comillas desbalanceadas, `fi`/`done` faltantes | Instantáneo |
| 2 | `shellcheck f` | Expansiones sin comillas, `cd` sin `\|\|`, SC2155, `cat` inútil, ~400 patrones | Instantáneo |
| 3 | `checkbashisms -f f` | Construcciones exclusivas de bash en un script `#!/bin/sh` | Instantáneo |
| 4 | `dash f` (ejecutar bajo el shell destino real) | Fallos de dialecto en tiempo de ejecución | Segundos |
| 5 | `sh -x f` con un `PS4` rico | Valores de expansión equivocados, rama inesperada tomada | Segundos |
| 6 | Tests unitarios con `bats` | Regresiones de lógica, violaciones del contrato de códigos de salida | Segundos |
| 7 | Inyección deliberada de fallos en staging | Camino de alerta roto, código de salida equivocado expuesto al supervisor | Minutos |

El escalón 7 es el que siempre se saltea y siempre el que importa durante un incidente: un camino de alerta que nunca se disparó es un camino de alerta que no existe.

### 13.2 `bash -n` y `shellcheck` en la práctica

```
$ cat -n rotate.sh
     1  #!/bin/bash
     2  set -euo pipefail
     3  DIR=/var/log/app
     4  for f in $DIR/*.log; do
     5      if [ -s $f ]
     6          gzip -9 "$f"
     7      fi
     8  done

$ bash -n rotate.sh
rotate.sh: line 6: syntax error near unexpected token `gzip'
rotate.sh: line 6: `        gzip -9 "$f"'
```

Falta `; then`. Arreglá eso, y después:

```
$ shellcheck rotate.sh

In rotate.sh line 4:
for f in $DIR/*.log; do
         ^--^ SC2086 (info): Double quote to prevent globbing and word splitting.

Did you mean:
for f in "$DIR"/*.log; do

In rotate.sh line 5:
    if [ -s $f ]; then
            ^-- SC2086 (info): Double quote to prevent globbing and word splitting.

Did you mean:
    if [ -s "$f" ]; then

For more information:
  https://www.shellcheck.net/wiki/SC2086 -- Double quote to prevent globbing ...
```

Los códigos de ShellCheck de alto valor para conocer por número:

| Código | Significado |
|---|---|
| SC1090/SC1091 | No se puede seguir un `source` dinámico; agregá `# shellcheck source=path` |
| SC2086 | Variable sin comillas — división en palabras y globbing |
| SC2046 | `$(...)` sin comillas — lo mismo |
| SC2006 | Backticks; usá `$( )` |
| SC2115 | `rm -rf "$dir/"` cuando `$dir` puede estar vacía; usá `${dir:?}` |
| SC2155 | `local x=$(cmd)` enmascara el exit status |
| SC2164 | `cd` sin `\|\| exit` |
| SC2181 | `if [ $? -eq 0 ]` — comprobá el comando directamente |
| SC2148 | Shebang ausente |
| SC30xx | Violaciones de sh POSIX (solo con `-s sh`) |

### 13.3 Trazado

```
$ export PS4='+ ${BASH_SOURCE##*/}:${LINENO}:${FUNCNAME[0]:-main}: '
$ bash -x ./deploy.sh staging
+ deploy.sh:3:main: set -euo pipefail
+ deploy.sh:5:main: ENV=staging
+ deploy.sh:6:main: NS=app-staging
+ deploy.sh:8:main: resolve_image staging
+ deploy.sh:14:resolve_image: registry.internal/app
+ deploy.sh:14:resolve_image: tag=v1.4.2
+ deploy.sh:15:resolve_image: printf '%s:%s\n' registry.internal/app v1.4.2
+ deploy.sh:8:main: image=registry.internal/app:v1.4.2
+ deploy.sh:9:main: kubectl -n app-staging set image deploy/app app=registry.internal/app:v1.4.2
```

Como `set -x` imprime los comandos **después** de la expansión, imprime secretos. Protegé la región sensible:

```sh
set +x
token=$(read_secret /run/secrets/api-token)
curl -fsS -H "Authorization: Bearer $token" "$url"
set -x
```

Mejor aún, en bash: `export BASH_XTRACEFD=9; exec 9>>/var/log/app/trace.log` envía la traza a un archivo separado con permisos restringidos en lugar de a la stdout del trabajo.

Redirigir una traza a un archivo de forma portable:

```
$ sh -x ./job.sh 2>/tmp/job.trace
$ grep -n 'DIR=' /tmp/job.trace
12:+ DIR=
```
Ahí está el bug: `DIR` se expandió vacía.

### 13.4 Tabla de diagnóstico

| Síntoma | Causa probable | Comando de confirmación | Solución |
|---|---|---|---|
| `bad interpreter: No such file or directory` y la ruta parece correcta | Finales de línea CRLF | `file s.sh` muestra "with CRLF line terminators" | `sed -i 's/\r$//' s.sh` |
| `bad interpreter` con `^M` visible | Lo mismo | `head -1 s.sh \| xxd` | Lo mismo |
| `Permission denied`, rc 126 | Falta el bit de ejecución, o montaje con `noexec` | `ls -l s.sh`; `findmnt -T s.sh -o TARGET,OPTIONS` | `chmod +x`, o mover fuera del sistema de archivos `noexec` |
| `command not found`, rc 127, funciona interactivamente | `PATH` distinto bajo cron/systemd | `systemctl show u.service -p Environment`; agregar `env` a la línea de cron | Fijar `PATH=` en la unidad/crontab, o usar rutas absolutas |
| `[[: not found` | bashism bajo `dash` | `head -1 s.sh` | Reescribir como `[ ]` o cambiar el shebang a `#!/bin/bash` |
| El script "tiene éxito" pero no hace nada | El pipeline enmascara el status; excepción de `set -e` | `echo "${PIPESTATUS[@]}"`; `bash -x` | `set -o pipefail`; comprobar los status explícitamente |
| `rm -rf` eliminó el árbol equivocado | Variable sin comillas/vacía | ShellCheck SC2115 | `${dir:?}` y poner comillas en todo |
| El contador del bucle queda en 0 al terminar | `cmd \| while` creó un subshell | `bash -x` muestra que la asignación ocurre | Redirigir con `< file` o `< <(cmd)` |
| Se saltea la última línea de un archivo | Sin salto de línea final | `tail -c 1 f \| xxd` | `while read -r l \|\| [ -n "$l" ]` |
| Nombres de archivo con espacios procesados como dos ítems | `for f in $(ls)` | ShellCheck SC2045 | Glob o `find -exec ... +` |
| El trabajo corre dos veces, corrompe datos | Sin exclusión mutua | `pgrep -fa script` | `flock -n`; `concurrencyPolicy: Forbid` |
| Un script en `/etc/cron.daily` nunca se ejecuta | El nombre de archivo tiene un punto | `run-parts --test /etc/cron.daily` | Renombrar sin extensión |
| El pod tarda el período de gracia completo en parar | El shell es PID 1, sin `exec` | `kubectl exec pod -- ps -o pid,comm` | `exec "$@"` en el entrypoint |
| `mktemp` falla en un contenedor | `readOnlyRootFilesystem: true`, sin `/tmp` escribible | `kubectl logs` muestra el error | Montar un `emptyDir` en `/tmp` |
| Un script setuid no da privilegio | El kernel ignora setuid en scripts `#!` | `./s.sh` imprime el uid del llamador | Usar `sudo` con una regla acotada |
| Código de salida 44 para 300 errores | `exit N` se envuelve mód 256 | `sh -c 'exit 300'; echo $?` | Devolver un código fijo, registrar el conteo |
| cron no envió nada ante el fallo | Sin MTA; `MAILTO` sin definir | `journalctl -t CRON`; `mailq` | Instalar un MTA o pasar a `OnFailure=` |

### 13.5 Testeo unitario de contratos de códigos de salida con `bats`

`tests/artifact-gc.bats`:

```bash
#!/usr/bin/env bats

setup() {
    TESTROOT=$(mktemp -d)
    export ARTIFACT_ROOT="$TESTROOT"
    SCRIPT=${BATS_TEST_DIRNAME}/../sbin/artifact-gc
}

teardown() {
    rm -rf "$TESTROOT"
}

@test "exits 66 when the artifact root does not exist" {
    run "$SCRIPT" -p /definitely/not/here
    [ "$status" -eq 66 ]
}

@test "exits 64 on a non-numeric retention" {
    run "$SCRIPT" -d thirty -p "$TESTROOT"
    [ "$status" -eq 64 ]
}

@test "removes files older than the retention window" {
    touch -d '60 days ago' "$TESTROOT/old.tar.gz"
    touch "$TESTROOT/new.tar.gz"
    run "$SCRIPT" -d 30 -p "$TESTROOT"
    [ "$status" -eq 0 ]
    [ ! -e "$TESTROOT/old.tar.gz" ]
    [ -e "$TESTROOT/new.tar.gz" ]
}

@test "handles filenames containing spaces and newlines" {
    touch -d '60 days ago' "$TESTROOT/an old file.tar.gz"
    run "$SCRIPT" -d 30 -p "$TESTROOT"
    [ "$status" -eq 0 ]
    [ ! -e "$TESTROOT/an old file.tar.gz" ]
}

@test "is a valid POSIX sh script" {
    run dash -n "$SCRIPT"
    [ "$status" -eq 0 ]
}
```

```
$ bats tests/artifact-gc.bats
artifact-gc.bats
 ✓ exits 66 when the artifact root does not exist
 ✓ exits 64 on a non-numeric retention
 ✓ removes files older than the retention window
 ✓ handles filenames containing spaces and newlines
 ✓ is a valid POSIX sh script

5 tests, 0 failures
```

---

## 14. Resumen orientado al examen

**Shebang.** Primera línea, `#!` en los bytes 0–1, ruta absoluta del intérprete, como máximo un argumento en Linux. `#!/bin/sh` en Debian/Ubuntu significa `dash`, no bash. Sin shebang → `ENOEXEC` de `execve`. Intérprete inválido → salida 126.

**Exit status.** `$?` después de cada pipeline en primer plano; 0 = éxito. `126` no ejecutable, `127` no encontrado, `128+N` terminado por la señal N. `exit N` se envuelve módulo 256. El status de un pipeline es el de su **último** comando salvo que se active `pipefail` (bash).

**Comprobar valores de retorno.** `if cmd; then`, `cmd && ok`, `cmd || fail`, `rc=$?` capturado de inmediato. Nunca `if [ $? -eq 0 ]` — probá el comando en sí.

**`test` / `[`.** El mismo builtin; `[` necesita un `]` de cierre. Poné comillas en cada operando. Archivos: `-e -f -d -r -w -x -s -L`. Cadenas: `-z -n = !=`. Enteros: `-eq -ne -lt -le -gt -ge`. Combiná con `&&`/`||` entre `[ ]` separados, no con `-a`/`-o`.

**Bucles.** `for v in list; do … done`; `while cmd; do … done`; `until cmd; do … done`; `break`/`continue` con nivel opcional. `for arg; do` itera sobre `"$@"`. `while IFS= read -r line; do … done < file` para entrada por líneas.

**Sustitución de comandos.** `$(cmd)` — anidable, preferida. `` `cmd` `` — legado. Ambas eliminan los saltos de línea finales. Poné siempre comillas al resultado.

**`seq`.** `seq LAST`, `seq FIRST LAST`, `seq FIRST STEP LAST`, `-w` relleno con ceros, `-s` separador, `-f` formato.

**`set`.** `-e` salir ante error, `-u` error ante variable no definida, `-x` traza, `-n` solo parsear, `-v` verboso, `-o pipefail` (bash). `set -- a b c` reemplaza los parámetros posicionales.

**`declare`.** Builtin de bash: `declare -i` entero, `-r` de solo lectura, `-a` array, `-A` array asociativo, `-x` exportar, `-f` función, `-p` imprimir. No es POSIX — los equivalentes portables son `readonly` y `export`.

**`exec`.** Con un comando: reemplaza el shell, manteniendo el PID. Sin comando: aplica las redirecciones al shell actual de forma permanente (`exec 3<file`, `exec >log 2>&1`).

**`.` (source).** Ejecuta un archivo en el shell actual; `source` es el sinónimo de bash. Busca en `PATH` si el argumento no tiene barras — escribí siempre `. ./file`.

**Funciones.** `name() { …; }` es la forma portable. `return N` fija el status; `$1…$@` son los argumentos de la función; `local` acota una variable.

**Correo condicional a root.** cron envía por correo cualquier salida del trabajo a `MAILTO` (por defecto: el propietario del crontab); el idiom es `cmd >/dev/null` para que solo stderr genere correo. Explícitamente: `printf … | mail -s "subject" root`, o `sendmail -t` con cabeceras `To:`/`Subject:`. En systemd: `OnFailure=`. En un contenedor: salir con estado distinto de cero y registrar en stderr.

**Ubicaciones.** `/usr/local/bin` (todos los usuarios), `/usr/local/sbin` (root), `~/bin` o `~/.local/bin` (por usuario), `/etc/cron.{hourly,daily,weekly,monthly}` (ejecutados por `run-parts`, nombres de archivo sin puntos), `/etc/cron.d` (formato crontab), `/etc/init.d` (SysV), `/etc/systemd/system` (unidades locales). Nunca `/usr/bin` ni `/usr/sbin` — esos pertenecen al gestor de paquetes.

**Permisos.** `0755` para ejecutables, `0644` para bibliotecas que se hacen source, `root:root` para scripts de sistema. **El bit setuid se ignora en scripts `#!` en Linux**; usá `sudo` con un `Cmnd_Alias` acotado en su lugar.

---

## 15. Referencias

**LPI — objetivos de certificación**
- Objetivos del examen LPIC-1 102, v5.0 (contiene el tema 105.2): https://www.lpi.org/our-certifications/exam-102-objectives/
- Objetivos del examen LPIC-1 101, v5.0: https://www.lpi.org/our-certifications/exam-101-objectives/
- Panorama de la certificación LPIC-1: https://www.lpi.org/our-certifications/lpic-1-overview/

**Estándares**
- POSIX.1-2024 (IEEE Std 1003.1-2024) — Shell Command Language: https://pubs.opengroup.org/onlinepubs/9799919799/utilities/V3_chap02.html
- POSIX — utilidad `test`: https://pubs.opengroup.org/onlinepubs/9799919799/utilities/test.html
- POSIX — utilidad `read`: https://pubs.opengroup.org/onlinepubs/9799919799/utilities/read.html
- POSIX — utilidad `getopts`: https://pubs.opengroup.org/onlinepubs/9799919799/utilities/getopts.html
- Filesystem Hierarchy Standard 3.0: https://refspecs.linuxfoundation.org/FHS_3.0/fhs/index.html

**GNU**
- GNU Bash Reference Manual: https://www.gnu.org/software/bash/manual/bash.html
- Bash — The Set Builtin: https://www.gnu.org/software/bash/manual/html_node/The-Set-Builtin.html
- Bash — Shell Parameter Expansion: https://www.gnu.org/software/bash/manual/html_node/Shell-Parameter-Expansion.html
- Bash — Exit Status: https://www.gnu.org/software/bash/manual/html_node/Exit-Status.html
- GNU Coreutils Manual (`seq`, `install`, `env`, `mktemp`): https://www.gnu.org/software/coreutils/manual/coreutils.html
- GNU Mailutils Manual: https://mailutils.org/manual/mailutils.html

**Shells y herramientas**
- dash — Debian Almquist Shell: https://manpages.debian.org/stable/dash/dash.1.en.html
- ShellCheck: https://www.shellcheck.net/ · índice del wiki: https://www.shellcheck.net/wiki/
- `checkbashisms` (devscripts): https://manpages.debian.org/stable/devscripts/checkbashisms.1.en.html
- Bats — Bash Automated Testing System: https://bats-core.readthedocs.io/
- `run-parts(8)`: https://manpages.debian.org/stable/debianutils/run-parts.8.en.html
- `flock(1)`, util-linux: https://man7.org/linux/man-pages/man1/flock.1.html

**Kernel e interfaces del sistema**
- `execve(2)` — scripts de intérprete: https://man7.org/linux/man-pages/man2/execve.2.html
- `sudoers(5)`: https://www.sudo.ws/docs/man/sudoers.man/
- `crontab(5)`: https://man7.org/linux/man-pages/man5/crontab.5.html

**systemd**
- `systemd.service(5)`: https://www.freedesktop.org/software/systemd/man/latest/systemd.service.html
- `systemd.unit(5)` — `OnFailure=`: https://www.freedesktop.org/software/systemd/man/latest/systemd.unit.html
- `systemd.timer(5)`: https://www.freedesktop.org/software/systemd/man/latest/systemd.timer.html
- `systemd.exec(5)` — directivas de sandboxing: https://www.freedesktop.org/software/systemd/man/latest/systemd.exec.html

**Kubernetes**
- CronJob: https://kubernetes.io/docs/concepts/workloads/controllers/cron-jobs/
- Jobs — `backoffLimit`, `activeDeadlineSeconds`: https://kubernetes.io/docs/concepts/workloads/controllers/job/
- ConfigMaps como volúmenes: https://kubernetes.io/docs/concepts/configuration/configmap/
- Security Context: https://kubernetes.io/docs/tasks/configure-pod-container/security-context/
- Ciclo de vida y terminación de contenedores: https://kubernetes.io/docs/concepts/containers/container-lifecycle-hooks/
- Configurar probes de Liveness, Readiness y Startup: https://kubernetes.io/docs/tasks/configure-pod-container/configure-liveness-readiness-startup-probes/