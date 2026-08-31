# LPIC-1 · Tema 103.1 — Trabajar en la línea de comandos

**Exámenes:** 101-500 (Tema 103, *Comandos GNU y Unix*) · **Peso:** 6.25
**Áreas de conocimiento clave:** comandos simples y secuencias de comandos en una línea · entorno del shell (definir, referenciar, exportar) · historial de comandos · invocar comandos dentro y fuera de `$PATH`
**Términos y utilidades:** `bash`, `echo`, `env`, `export`, `pwd`, `set`, `unset`, `type`, `which`, `man`, `uname`, `history`, `.bash_history`, quoting

---

## 1. Motivación: el problema arquitectónico detrás de "simplemente ejecutá un comando"

Toda revisión de incidente que termina con *"pero en mi máquina funciona"* es, mecánicamente, un problema del **entorno del proceso**. No hay magia en esto. El shell es un programa de espacio de usuario cuyo trabajo completo consiste en convertir una línea de texto en una llamada a `execve(2)`:

```c
int execve(const char *pathname, char *const argv[], char *const envp[]);
```

Tres entradas. Ese es todo el contrato con el kernel. Todo lo que vas a leer en este tema — resolución de `PATH`, quoting, `export`, `env -i`, hashing, expansión del historial — existe para controlar qué termina en esos tres argumentos, y **quién los hereda después**.

Los modos de falla en producción que se derivan de equivocarse en esto no son académicos:

| Falla en producción | Causa raíz en términos de 103.1 |
|---|---|
| Un job de CI pasa localmente y falla en el runner con `command not found` | El `PATH` difiere; el shell interactivo hizo source de `~/.bashrc`, el runner no interactivo no |
| Un servicio de `systemd` arranca a mano pero falla en el arranque del sistema | `ExecStart=` usó un nombre relativo; `systemd` nunca hace búsqueda por `PATH` como sí la hace un shell interactivo, y su entorno es mínimo por diseño |
| Un job de cron produce silenciosamente salida vacía a las 03:00 | cron te da `PATH=/usr/bin:/bin` y ningún `LANG`; un `sort`/`date` dependiente de la locale cambia de comportamiento |
| Un script de despliegue borra el árbol equivocado | Una variable sin comillas que contenía un espacio pasó por división en palabras y expansión de rutas |
| Un token de API aparece en `~/.bash_history` y luego es extraído de un backup | `HISTCONTROL` sin configurar; el operador tipeó el secreto sin espacio inicial |
| `rm` falla con `Argument list too long` en un host de rotación de logs | La combinación de `argv[]` + `envp[]` excedió el límite `MAX_ARG_STRLEN`/derivado del stack del kernel |
| Un binario existe, es ejecutable, y aun así reporta `No such file or directory` | Tabla hash de bash desactualizada, o falta el **intérprete ELF** — el ENOENT se refiere al loader, no a tu archivo |

Un SRE que entiende la cadena `fork(2)` → `execve(2)` → `environ(7)` depura las siete con el mismo modelo mental. Ese modelo es lo que te compra este tema, y es la razón por la que un objetivo "para principiantes" tiene peso real en el examen y muchísimo más peso en la práctica.

---

## 2. La mecánica: qué pasa realmente cuando apretás Enter

### 2.1 El ciclo de vida de un comando

```
  read line  ──► history expansion (interactive only)
             ──► alias expansion
             ──► lexical analysis / tokenization  (metacharacters, quoting)
             ──► parsing into commands, pipelines, lists
             ──► expansions (see §5.1)
             ──► redirection setup
             ──► command resolution (see §3)
             ──► builtin?  run in the current shell process
                 function? run in the current shell process
                 external? fork(2) ──► [child] execve(2) ──► exec'd program
                                  ──► [parent] wait4(2) ──► $? set from exit status
```

Dos consecuencias que el examen adora y que producción castiga:

1. **Los builtins corren en el shell actual.** `cd`, `export`, `unset`, `read`, `pwd`, `history` *tienen* que ser builtins, porque un proceso hijo no puede cambiar el directorio de trabajo ni el entorno de su padre. Esto no es una elección de implementación; es una consecuencia del modelo de procesos.
2. **Todo lo que un comando externo recibe, lo recibió en el momento del `execve`.** El entorno es una *instantánea copiada dentro de la nueva imagen del proceso*, no un espacio de nombres compartido y vivo. Cambiar `export FOO=bar` después de que un programa arrancó tiene exactamente cero efecto sobre ese programa en ejecución.

Verificá ambas afirmaciones directamente:

```console
$ echo $$          # PID of the current shell
4471

$ pwd
/home/sre

$ ( cd /tmp; pwd )   # subshell: a fork, no exec
/tmp

$ pwd                # parent is untouched
/home/sre

$ echo $$ ; ( echo $$ ; echo $BASHPID )
4471
4471
9330
```

`$$` es heredado deliberadamente por los subshells (es el PID *del shell* tal como lo ve el script); `$BASHPID` es el PID real y actual. Confundir ambos produce archivos PID que apuntan a un proceso que ya no existe — una causa clásica de "el servicio está arriba pero el health check lo mata".

### 2.2 Demostrar que el entorno es una instantánea

```console
$ sleep 600 &
[1] 9412

$ tr '\0' '\n' < /proc/9412/environ | grep -c .
34

$ export CANARY=hello
$ tr '\0' '\n' < /proc/9412/environ | grep CANARY || echo "not present"
not present
```

`/proc/<pid>/environ` es el bloque separado por NUL que el kernel colocó en el stack del proceso en el momento del `execve`. No se actualiza. (Un proceso puede modificar su propia copia vía `putenv(3)`/`setenv(3)`, y glibc moverá el bloque fuera de la región original del stack cuando crece — que es exactamente por qué `/proc/<pid>/environ` puede divergir silenciosamente del estado real de un daemon de larga vida. Confiá en él como *"con qué fue lanzado"*, nunca como *"qué cree actualmente"*.)

---

## 3. Resolución de comandos: `type`, `which`, `command -v`, y la tabla hash

### 3.1 El orden de resolución que aplica bash

Para una palabra de comando simple, bash resuelve en este orden fijo:

| # | Categoría | Ejemplo | Cómo evitarlo |
|---|---|---|---|
| 1 | **Alias** (solo shells interactivos, salvo `shopt -s expand_aliases`) | `alias ll='ls -l'` | `\ll`, `'ll'`, `command ll` |
| 2 | **Palabra clave** (palabra reservada) | `if`, `for`, `while`, `[[`, `time`, `function` | quoting: `\time` |
| 3 | **Función** | `deploy() { ...; }` | `command deploy` |
| 4 | **Builtin** | `cd`, `echo`, `pwd`, `test`, `kill` | `env echo`, `/bin/echo`, `enable -n echo` |
| 5 | **Ruta en la tabla hash** | recordada de una búsqueda previa | `hash -r`, `set +h` |
| 6 | **Búsqueda en `$PATH`**, de izquierda a derecha, gana la primera coincidencia | `/usr/local/bin/kubectl` | ruta absoluta o `./relativa` |

Cualquier cosa que contenga un `/` salta los pasos 1–6 por completo y va directo al `execve` sobre esa ruta. Esta es toda la razón por la que `./script.sh` existe como idioma: `.` no está (y no debe estar) en `PATH`.

### 3.2 Interrogar la resolución — comparación de herramientas

```console
$ type -a echo
echo is a shell builtin
echo is /usr/bin/echo
echo is /bin/echo

$ type -t if
keyword

$ type -t ll
alias

$ type -P echo          # force a PATH-only lookup, ignore builtin/function/alias
/usr/bin/echo

$ command -v systemctl
/usr/bin/systemctl

$ command -V systemctl
systemctl is /usr/bin/systemctl

$ which -a python3
/usr/local/bin/python3
/usr/bin/python3
```

| Herramienta | Naturaleza | ¿Ve builtins/funciones/aliases? | ¿Usa el estado real del shell que la invoca? | Portabilidad | Veredicto para scripts |
|---|---|---|---|---|---|
| `type` | builtin de bash | **Sí** (`-a` muestra todos, `-t` imprime la categoría) | Sí | bash/ksh/zsh; salida no portable a POSIX | Lo mejor para **humanos depurando** |
| `command -v` | builtin del shell POSIX | **Sí** | Sí | POSIX — portable en todos lados | **Usá esto en scripts** |
| `which` | binario externo (o un script de la era csh) | **No** — solo archivos en `$PATH` | No: relee `$PATH` de su propio entorno | No estándar, el comportamiento difiere por distro; Fedora ha deprecado el paquete `which` en favor de `command -v` | Evitalo en código nuevo; **conocelo para el examen** |
| `whereis` | externo | No; busca en directorios estándar fijados en el código | No | util-linux | Localizar binario + fuente + página de manual |
| `hash` | builtin de bash | Muestra solo la caché de rutas recordadas | Sí | bash | Diagnosticar bugs de rutas desactualizadas |

**Por qué `which` te engaña exactamente en el momento en que lo necesitás:** es un proceso separado. No puede ver que tu shell tiene una función llamada `kubectl` que ensombrece al binario, y relee `PATH` de *su propia* copia del entorno. Si cambiaste `PATH` sin exportarlo, `which` y tu shell no coinciden:

```console
$ PATH=/opt/toolchain/bin:$PATH        # assignment only — NOT exported
$ type -P mytool
/opt/toolchain/bin/mytool
$ which mytool
/usr/bin/which: no mytool in (/usr/bin:/bin:/usr/sbin:/sbin)
```

Eso no es un bug. `PATH` ya había sido exportado por el proceso de login, así que reasignarlo *sí* actualiza el valor exportado en bash — pero el ejemplo de arriba funciona porque `PATH` conserva su atributo de exportación. Donde la divergencia realmente muerde es con una función del shell o un builtin. Preferí `type -a`.

### 3.3 La tabla hash — el bug de "el archivo existe pero bash dice que no"

Bash cachea las búsquedas exitosas en `PATH`. Después de que una actualización de paquete reubica un binario, la caché queda desactualizada:

```console
$ hash
hits	command
   4	/usr/local/bin/kubectl
   1	/usr/bin/curl

$ sudo dnf -y upgrade kubectl        # binary moves to /usr/bin/kubectl
...
$ kubectl version --client
bash: /usr/local/bin/kubectl: No such file or directory

$ ls -l /usr/bin/kubectl
-rwxr-xr-x. 1 root root 54018048 Aug 12 09:31 /usr/bin/kubectl

$ hash -r                            # forget everything
$ kubectl version --client
Client Version: v1.31.4
```

| Comando | Efecto |
|---|---|
| `hash` | Listar la caché con contadores de aciertos |
| `hash -r` | Limpiar toda la caché |
| `hash -d kubectl` | Olvidar una sola entrada |
| `hash -p /opt/bin/kubectl kubectl` | Fijar un nombre a una ruta sin búsqueda en `PATH` |
| `set +h` | Desactivar el hashing por completo (útil en shells interactivos de larga vida durante migraciones; cuesta un recorrido de `PATH` por comando) |

**Regla de producción:** cualquier automatización que instale o reubique binarios y luego los invoque en el *mismo* shell debe llamar a `hash -r` después del paso de instalación. Esta es una causa genuina y recurrente de jobs de CI inestables.

### 3.4 `PATH` como superficie de ataque

```console
$ echo "$PATH"
/home/sre/.local/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin
```

Tres reglas que pertenecen a toda línea base de endurecimiento:

1. **Nunca incluyas `.`**, y nunca dejes un campo vacío. Un campo vacío significa "directorio actual". Las tres siguientes son equivalentes a poner `.` en `PATH`:
   `PATH=:/usr/bin` · `PATH=/usr/bin:` · `PATH=/usr/bin::/bin`
2. **El orden es confianza.** Gana la primera coincidencia, así que entradas tempranas con permiso de escritura permiten que cualquier usuario que pueda escribir ahí ensombrezca `ls` para todos los que usen ese `PATH`.
3. **`sudo` deliberadamente no confía en tu `PATH`.** Con `Defaults secure_path` (el valor por defecto en RHEL/Fedora/Debian), `sudo` lo *reemplaza*:

```console
$ sudo grep -E 'secure_path|env_reset' /etc/sudoers
Defaults    env_reset
Defaults    secure_path = /sbin:/bin:/usr/sbin:/usr/bin

$ which terraform
/home/sre/.local/bin/terraform

$ sudo terraform version
sudo: terraform: command not found

$ sudo env "PATH=$PATH" terraform version     # explicit, auditable
Terraform v1.9.5

$ sudo -E printenv PATH                       # -E preserves env, subject to env_check/env_keep
/sbin:/bin:/usr/sbin:/usr/bin
```

Fijate en el último: `sudo -E` preserva la mayoría de las variables pero `secure_path` sigue sobrescribiendo `PATH`. Los operadores que "arreglan" esto borrando `secure_path` han convertido una molestia de usabilidad en un vector de escalada de privilegios. El arreglo correcto es una ruta absoluta o un `sudo env "PATH=..."` explícito.

---

## 4. Variables del shell vs variables de entorno

### 4.1 La distinción

* Una **variable del shell** vive solo en la memoria propia del proceso shell.
* Una **variable de entorno** es una variable del shell que lleva el *atributo de exportación*, lo que significa que bash la copia dentro de `envp[]` en el próximo `execve`.

```console
$ LOCAL_ONLY=local
$ export EXPORTED=inherited

$ echo "$LOCAL_ONLY $EXPORTED"
local inherited

$ bash -c 'echo "child sees: [$LOCAL_ONLY] [$EXPORTED]"'
child sees: [] [inherited]
```

Definir y exportar en un solo paso, o agregar el atributo después — ambas son equivalentes:

```console
$ export API_ENDPOINT=https://api.internal.example.com
$ API_TIMEOUT=30
$ export API_TIMEOUT
$ declare -x API_RETRIES=5           # declare -x is a synonym for export
$ export -p | grep API_
declare -x API_ENDPOINT="https://api.internal.example.com"
declare -x API_RETRIES="5"
declare -x API_TIMEOUT="30"
```

Eliminar:

```console
$ export -n API_TIMEOUT      # drop the export attribute, KEEP the shell variable
$ echo "$API_TIMEOUT"
30
$ bash -c 'echo "[$API_TIMEOUT]"'
[]

$ unset -v API_TIMEOUT       # remove the variable entirely
$ echo "[$API_TIMEOUT]"
[]

$ unset -f mydeployfunc      # -f removes a function, not a variable
```

Sin `-v`/`-f`, `unset` prueba primero con la variable y recurre a la función — es ambiguo, así que **sé siempre explícito en scripts**.

### 4.2 Herramientas de inspección — compromisos

| Comando | Muestra | ¿Incluye variables del shell no exportadas? | ¿Incluye funciones? | ¿Puede *ejecutar* un comando? | Notas |
|---|---|---|---|---|---|
| `env` | el entorno de un proceso nuevo | No | No | **Sí** — `env [-i] [VAR=v]… cmd` | Binario externo (`/usr/bin/env`). La forma que ejecuta `cmd` es su verdadero poder |
| `printenv` | el entorno | No | No | No | `printenv VAR` sale con 1 si no está definida — prueba de existencia scriptable |
| `export -p` | variables exportadas, en forma `declare -x` reutilizable | No | No | No | La salida se puede pasar por `source` |
| `set` (sin argumentos) | **todas** las variables del shell + funciones | **Sí** | Sí (también los cuerpos, salvo `set -o posix`) | No | Muy ruidoso; pasalo por `grep` |
| `declare -p` | todas las variables con sus atributos | Sí | Con `-f`/`-F` | No | Muestra `-x` exportación, `-r` solo lectura, `-i` entero, `-a`/`-A` arrays |
| `compgen -v` | solo los nombres | Sí | No | No | Ideal para comparar dos shells |

```console
$ printenv HOME
/home/sre

$ printenv NOPE_NOT_SET; echo "exit=$?"
exit=1

$ declare -p PATH HOME LOCAL_ONLY
declare -x PATH="/home/sre/.local/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
declare -x HOME="/home/sre"
declare -- LOCAL_ONLY="local"
```

El `--` en `LOCAL_ONLY` frente al `-x` en `PATH` es el atributo de exportación, visible. `declare -p` es el diagnóstico más útil de todo este tema.

### 4.3 `env` como lanzador de procesos — el uso relevante en producción

`env` no es principalmente una herramienta para "imprimir el entorno". Es una herramienta para **construir** el entorno de un proceso hijo:

```console
$ env DEPLOY_ENV=staging LOG_LEVEL=debug ./deploy.sh      # one-shot additions
```

```console
$ env -i /bin/bash --noprofile --norc -c 'echo "[$PATH]"; env | wc -l'
[]
0
```

`env -i` arranca desde un entorno completamente vacío — y fijate que `PATH` está *vacío*, no "por defecto". Bash luego recurre a una ruta por defecto compilada en el binario solo para sus propias búsquedas. Esta es la mejor herramienta que existe para reproducir "falla en cron / en el contenedor / bajo systemd":

```console
$ env -i HOME="$HOME" PATH=/usr/bin:/bin ./backup.sh
./backup.sh: line 12: aws: command not found
```

Acabás de reproducir la falla de cron de las 03:00 a las 11:00 a plena luz del día, de forma determinista. Formas adicionales:

```console
$ env -u LD_PRELOAD -u LD_LIBRARY_PATH ./legacy-binary     # remove specific vars
$ env -C /srv/app ./run.sh                                 # chdir first (coreutils ≥ 8.28)
$ env -0 | tr '\0' '\n' | sort | head -3                   # NUL-safe listing
DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/1000/bus
HOME=/home/sre
LANG=en_US.UTF-8
```

`env` es también la razón por la que `#!/usr/bin/env python3` es el shebang portable: el manejador de shebang del kernel **no hace búsqueda por `PATH`**, así que delegás la búsqueda a `env`, que sí hace una.

### 4.4 El mapa de fronteras del entorno

Saber *dónde* se re-establece el entorno es la diferencia entre adivinar y diagnosticar:

| Contexto | Origen del entorno | ¿Lee `~/.bashrc`? | ¿Lee `/etc/profile`? |
|---|---|---|---|
| Shell de login (consola, `ssh host`) | PAM (`/etc/environment`, `pam_env`) → `/etc/profile` → `~/.bash_profile` | Solo si `~/.bash_profile` le hace source (la convención habitual) | Sí |
| Interactivo sin login (terminal en un escritorio, `bash`) | heredado del padre | **Sí** | No |
| No interactivo (`ssh host 'cmd'`, script) | heredado; `$BASH_ENV` si está definida | No (bash lo saltea — el guard temprano `[ -z "$PS1" ] && return` en los `bashrc` de las distros existe por esto) | No |
| Job de `cron` | el entorno mínimo de crond; `PATH=/usr/bin:/bin`, `SHELL=/bin/sh`, más las asignaciones en el propio archivo crontab | No | No |
| Servicio de `systemd` | `DefaultEnvironment=`, `Environment=`/`EnvironmentFile=` de la unidad; **ningún shell en absoluto** salvo que invoques uno | No | No |
| `ENTRYPOINT` de contenedor | `ENV` de la imagen + `-e`/`env:` en tiempo de ejecución | No (PID 1 normalmente no es un shell de login) | No |
| Contenedor de Kubernetes | `ENV` de la imagen + `env:`/`envFrom:` + variables de descubrimiento de servicios inyectadas | No | No |

**`systemd` merece una advertencia explícita:** `ExecStart=` requiere una **ruta absoluta** para el ejecutable, no realiza ninguna búsqueda en `PATH`, y no hace expansión de shell. `ExecStart=/bin/sh -c 'foo | bar'` es la forma de volver a optar por un shell — y deberías hacerlo conscientemente, porque acabás de reintroducir quoting y `PATH` en tu unidad.

---

## 5. Quoting, expansión y secuencias de comandos en una línea

### 5.1 El orden de expansión — memorizá esto

Bash realiza las expansiones en este orden, y el orden es *por qué* ciertas cosas "obvias" no funcionan:

| # | Expansión | Ejemplo | Notas |
|---|---|---|---|
| 1 | Llaves | `file{1..3}.log` → `file1.log file2.log file3.log` | Puramente textual; ocurre **antes** que las variables, que es por qué `{1..$n}` no funciona |
| 2 | Tilde | `~/logs`, `~root` | Solo al comienzo de una palabra, sin comillas |
| 3 | Parámetro / variable | `$VAR`, `${VAR:-default}`, `${VAR#prefix}` | |
| 4 | Sustitución de comandos | `$(date -u +%F)`, backticks | Anidable con `$()`; los backticks no |
| 5 | Aritmética | `$(( 3 * COUNT ))` | Solo enteros |
| 6 | Sustitución de procesos | `<(cmd)`, `>(cmd)` | extensión de bash; se realiza junto con 3–5 |
| 7 | **División en palabras** | según `$IFS` (por defecto: espacio, tab, newline) | **Solo sobre resultados sin comillas de 3–6** |
| 8 | Expansión de rutas (globbing) | `*.log`, `?`, `[a-z]` | Suprimida por `set -f` |
| 9 | Eliminación de comillas | | Los caracteres literales de comillas se quitan al final |

Los pasos 7 y 8 son los dos que destruyen sistemas en producción, y ambos se desactivan con comillas dobles.

### 5.2 Reglas de quoting

| Forma | Protege de | Sigue expandiendo | Uso canónico |
|---|---|---|---|
| `\c` (barra invertida) | todo, un carácter | — | escapar un solo metacarácter; continuación de línea con `\`+newline |
| `'simples'` | **todo** | nada en absoluto — no podés incrustar un `'` | cadenas literales, regexes, programas `awk`/`sed`, contraseñas |
| `"dobles"` | división en palabras, globbing, la mayoría de los metacaracteres | `$`, `` ` ``, `\`, y `!` (historial, shells interactivos) | **referencias a variables — la opción por defecto** |
| `$'ansi-c'` | — | interpreta `\n`, `\t`, `\x41`, `\u00e9` | delimitadores, caracteres de control: `IFS=$'\n\t'` |
| `"$@"` | división de cada elemento | se expande a palabras separadas correctamente entrecomilladas | reenviar los argumentos de un script — nunca `$*`, nunca `$@` sin comillas |

Demostración de por qué importa:

```console
$ TARGET="/srv/app logs"
$ mkdir -p "$TARGET"

$ ls -d $TARGET
ls: cannot access '/srv/app': No such file or directory
ls: cannot access 'logs': No such file or directory

$ ls -d "$TARGET"
'/srv/app logs'
```

Ahora imaginá que el comando era `rm -rf $TARGET` y `TARGET` venía de una variable de CI que estaba vacía:

```console
$ TARGET=""
$ echo rm -rf $TARGET/          # dry-run with echo FIRST. Always.
rm -rf /
```

**Dos hábitos que previenen esta clase de caída:** entrecomillá cada expansión, y prefijá los one-liners destructivos con `echo` hasta que la salida sea exactamente lo que pretendés.

El gotcha del `!` dentro de comillas dobles, solo en shells interactivos:

```console
$ echo "Deploy failed!"
bash: !": event not found

$ echo 'Deploy failed!'
Deploy failed!

$ set +H                        # disable history expansion for this shell
$ echo "Deploy failed!"
Deploy failed!
```

### 5.3 Secuencias de comandos en una línea

| Operador | Semántica | Estado de salida de la lista | ¿Corre en un subshell? |
|---|---|---|---|
| `a ; b` | secuencial, incondicional | estado de `b` | no |
| `a && b` | ejecutar `b` solo si `a` tuvo éxito (`$? == 0`) | el último ejecutado | no |
| `a \|\| b` | ejecutar `b` solo si `a` falló | el último ejecutado | no |
| `a \| b` | stdout de `a` → stdin de `b`; ambos arrancan concurrentemente | estado de `b` (salvo con `pipefail`) | **sí**, cada etapa |
| `a \|& b` | forma abreviada de `a 2>&1 \| b` | igual que arriba | sí |
| `a &` | en segundo plano; el shell no espera | 0 inmediatamente; estado real vía `wait %1` | sí |
| `( a; b )` | agrupar en un **subshell** — los cambios de entorno/cwd se descartan | último comando | sí |
| `{ a; b; }` | agrupar en el shell **actual** (notá el `;` y los espacios obligatorios) | último comando | no |

```console
$ mkdir -p /srv/release && cd /srv/release && tar xzf /tmp/app.tgz && echo OK
OK

$ systemctl is-active nginx || systemctl start nginx
active

$ false | true ; echo "status=$?"
status=0

$ set -o pipefail
$ false | true ; echo "status=$?"
status=1

$ set +o pipefail
$ false | true ; echo "PIPESTATUS=(${PIPESTATUS[@]}) status=$?"
PIPESTATUS=(1 0) status=0
```

`PIPESTATUS` es la razón por la que `curl … | jq …` "tiene éxito" silenciosamente cuando `curl` devuelve un cuerpo 404. Cualquier pipeline sobre cuyo resultado actúes necesita `set -o pipefail` o una verificación explícita de `PIPESTATUS`.

La convención de estados de salida en sí misma vale la pena enunciarla con precisión: `0` = éxito; `1`–`125` = los códigos de falla propios del programa; `126` = encontrado pero no ejecutable; `127` = **no encontrado**; `128+N` = terminado por la señal `N` (así que `137` = `128+9`, SIGKILL — el OOM killer o una liveness probe de Kubernetes).

```console
$ /etc/hostname ; echo $?
bash: /etc/hostname: Permission denied
126

$ nosuchcmd ; echo $?
bash: nosuchcmd: command not found
127

$ sleep 100 & kill -9 %1 ; wait ; echo $?
[1] 9871
[1]+  Killed                  sleep 100
137
```

### 5.4 El preámbulo de modo estricto

Todo script de producción no trivial arranca con esto, y cada línea es un concepto de 103.1:

```bash
#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'
```

| Flag | Forma larga | Efecto | Salvedad que debés conocer |
|---|---|---|---|
| `-e` | `errexit` | salir ante cualquier estado no-cero no manejado | suprimido dentro de condiciones `if`, `&&`, `||`, `!` — por diseño |
| `-u` | `nounset` | error al expandir una variable no definida | `"${1:-}"` para argumentos opcionales; combinalo con `${VAR:?message}` |
| `-o pipefail` | — | un pipeline falla si **cualquier** etapa falla | atrapa la trampa de `curl \| jq` |
| `-E` | `errtrace` | las traps `ERR` son heredadas por funciones y subshells | necesario para que funcione un manejador de errores |
| `-x` | `xtrace` | imprimir cada comando expandido a stderr | el mejor interruptor de depuración que existe; ver §7.1 |
| `-f` | `noglob` | desactivar la expansión de rutas | para manejar nombres de archivo no confiables |
| `IFS=$'\n\t'` | — | quitar el espacio como separador de palabras | hace que la división accidental sea mucho menos destructiva |

---

## 6. Historial de comandos

### 6.1 Las variables que lo gobiernan

| Variable / ajuste | Propósito | Valor sensato para producción |
|---|---|---|
| `HISTFILE` | archivo donde se escribe el historial | `~/.bash_history` (por defecto) |
| `HISTSIZE` | comandos conservados **en memoria** | `10000` |
| `HISTFILESIZE` | líneas conservadas **en el archivo** tras el truncado | `20000` |
| `HISTCONTROL` | `ignorespace` \| `ignoredups` \| `ignoreboth` \| `erasedups` | `ignoreboth:erasedups` |
| `HISTIGNORE` | patrones glob separados por dos puntos que nunca se registran | `'ls:ls *:cd:pwd:history:* --token=*:* --password=*'` |
| `HISTTIMEFORMAT` | formato strftime mostrado por `history`; **también habilita las marcas de tiempo en el archivo** | `'%F %T '` |
| `shopt -s histappend` | agregar al final al salir en lugar de sobrescribir | **activado** — obligatorio con múltiples terminales |
| `shopt -s cmdhist` | almacenar un comando multilínea como una sola entrada del historial | activado (por defecto) |
| `set +o history` / `set +H` | desactivar el registro / desactivar la expansión `!` | para una sesión donde se manejan secretos |

```console
$ cat >> ~/.bashrc <<'EOF'
# --- history hardening -------------------------------------------------
HISTSIZE=10000
HISTFILESIZE=20000
HISTCONTROL=ignoreboth:erasedups
HISTIGNORE='ls:ls *:cd:cd *:pwd:history:clear:*--token=*:*--password=*:*AWS_SECRET*'
HISTTIMEFORMAT='%F %T '
shopt -s histappend cmdhist
PROMPT_COMMAND='history -a'
# -----------------------------------------------------------------------
EOF

$ exec bash -l
$ history 4
 1042  2026-08-26 11:04:12 systemctl status nginx
 1043  2026-08-26 11:04:31 journalctl -u nginx -n 50 --no-pager
 1044  2026-08-26 11:05:02 ss -ltnp
 1045  2026-08-26 11:05:19 history 4
```

Con `HISTTIMEFORMAT` definida, bash escribe una línea de comentario con el epoch antes de cada entrada:

```console
$ tail -4 ~/.bash_history
#1756206302
ss -ltnp
#1756206319
history 4
```

### 6.2 El builtin `history`

| Invocación | Efecto |
|---|---|
| `history` | imprimir la lista en memoria |
| `history 20` | las últimas 20 entradas |
| `history -a` | **agregar** las nuevas entradas en memoria a `HISTFILE` (la clave para la cordura con múltiples terminales) |
| `history -r` | leer `HISTFILE` y agregarlo a la lista en memoria |
| `history -n` | leer solo las líneas *aún no* leídas de `HISTFILE` |
| `history -w` | sobrescribir `HISTFILE` con la lista en memoria |
| `history -c` | limpiar la lista en memoria |
| `history -d 1043` | borrar la entrada 1043 (`-d inicio-fin` para un rango en bash ≥ 5.0) |
| `history -p '!!'` | expandir sin ejecutar — vista previa segura |
| `history -s 'cmd'` | inyectar una entrada sin ejecutarla |

**El problema de múltiples terminales.** Por defecto, el historial se escribe solo al salir del shell, y gana el último shell en salir — los comandos de tus otras tres terminales desaparecen. `shopt -s histappend` más `PROMPT_COMMAND='history -a'` escribe después de cada prompt. Agregá `history -n` al `PROMPT_COMMAND` si además querés *ver* los comandos de otras sesiones; la mayoría de los operadores no lo hacen, porque vuelve no determinista la flecha arriba.

**El problema del SIGKILL.** El historial lo vuelca bash mismo. Una ventana de terminal cerrada con `kill -9`, un OOM kill o un reinicio duro pierden todo lo posterior a la última escritura. `history -a` en `PROMPT_COMMAND` es la mitigación.

### 6.3 Expansión del historial (`!`)

La realiza la **biblioteca de historial, antes del parseo** — que es por qué ocurre incluso dentro de comillas dobles y por qué el quoting no puede protegerte fácilmente.

| Designador | Significado | Ejemplo |
|---|---|---|
| `!!` | comando anterior | `sudo !!` |
| `!n` / `!-n` | entrada número *n* / *n* comandos hacia atrás | `!1043` |
| `!string` | el comando más reciente que empieza con `string` | `!systemctl` |
| `!?string?` | el comando más reciente que *contiene* `string` | `!?nginx?` |
| `!$` / `!^` / `!*` | último argumento / primer argumento / todos los argumentos del comando anterior | `mkdir /srv/x && cd !$` |
| `!!:2` / `!!:2-3` | palabra 2 / palabras 2–3 del comando anterior | |
| `^old^new^` | volver a ejecutar el comando anterior con el primer `old` reemplazado | |
| `!!:gs/old/new/` | sustitución global | |
| modificador `:p` | **imprimir, no ejecutar** | `!systemctl:p` |

```console
$ systemctl restart nginx
Failed to restart nginx.service: Access denied
$ sudo !!
sudo systemctl restart nginx
$ ^nginx^haproxy
sudo systemctl restart haproxy
```

**Regla de seguridad para shells privilegiados:** siempre agregá `:p` primero cuando vuelvas al historial con `!string`. `!rm:p` imprime; `!rm` ejecuta. La diferencia en pulsaciones es de dos caracteres; la diferencia en radio de destrucción es un sistema de archivos. En el mismo espíritu, `Ctrl-r` (búsqueda incremental inversa) es estrictamente más seguro que `!string`, porque *ves* el comando antes de apretar Enter.

### 6.4 El historial es un artefacto de seguridad

`~/.bash_history` es un archivo de texto plano, modo `0600`, que es capturado por cada backup del directorio home, cada imagen de contenedor construida desde un host vivo, y cada imagen forense. Tratalo en consecuencia:

```console
$ ls -l ~/.bash_history
-rw-------. 1 sre sre 48213 Aug 26 11:05 /home/sre/.bash_history

$ grep -nEi 'token|password|secret|apikey|BEGIN (RSA|OPENSSH) PRIVATE' ~/.bash_history
811:export VAULT_TOKEN=hvs.CAESIJ4xR2c...
```

Manejo correcto, en orden de preferencia:

1. **Nunca tipees el secreto.** Leelo de un archivo o de un gestor de secretos: `export VAULT_TOKEN="$(vault login -field=token …)"`, `read -rs TOKEN`, `--password-stdin`.
2. **Prefijá con un espacio** (requiere que `HISTCONTROL` incluya `ignorespace`).
3. **Desactivá el registro para la sesión:** `set +o history` … `set -o history`.
4. **Remediá después del hecho:** `history -d <n>` y luego `history -w`, *y rotá la credencial* — ya está en el historial en disco del archivo, en el scrollback de tu terminal, y posiblemente en un backup. Borrar es limpieza, no remediación.

```console
$ read -rs -p "Vault token: " VAULT_TOKEN && export VAULT_TOKEN
Vault token: 
$ echo "${#VAULT_TOKEN}"      # verify length only, never the value
95
```

---

## 7. Manifiestos de infraestructura: los mismos conceptos, a escala de plataforma

Todo lo anterior reaparece textualmente en los manifiestos que escribís como ingeniero de plataforma. Estos son completos y sintácticamente válidos.

### 7.1 Kubernetes — todas las formas en que un contenedor obtiene su entorno

```yaml
---
apiVersion: v1
kind: ConfigMap
metadata:
  name: shell-demo-config
  namespace: platform-training
data:
  LOG_LEVEL: "debug"
  API_ENDPOINT: "https://api.internal.example.com"
  # A whole file can be mounted and sourced by an entrypoint script.
  app.env: |
    DEPLOY_ENV=staging
    FEATURE_FLAGS=canary,tracing
---
apiVersion: v1
kind: Secret
metadata:
  name: shell-demo-secret
  namespace: platform-training
type: Opaque
stringData:
  API_TOKEN: "s3cr3t-rotate-me"
---
apiVersion: v1
kind: Pod
metadata:
  name: shell-env-demo
  namespace: platform-training
  labels:
    app.kubernetes.io/name: shell-env-demo
    app.kubernetes.io/component: training
spec:
  restartPolicy: Never
  securityContext:
    runAsNonRoot: true
    runAsUser: 65532
    runAsGroup: 65532
    fsGroup: 65532
    seccompProfile:
      type: RuntimeDefault
  containers:
    - name: shell
      image: debian:12-slim
      imagePullPolicy: IfNotPresent
      # command == ENTRYPOINT (execve argv[0]); args == CMD.
      # This is exec form: NO shell is involved, so $VAR is NOT expanded here
      # by a shell — Kubernetes performs its own $(VAR) substitution instead.
      command: ["/bin/bash"]
      args:
        - "-c"
        - |
          set -Eeuo pipefail
          echo "=== argv/exec identity ==="
          echo "pid=$$  bashpid=$BASHPID  shell=$0"
          echo "=== PATH resolution ==="
          echo "PATH=$PATH"
          command -v bash cat env || true
          echo "=== environment (sorted) ==="
          env | sort
          echo "=== sourcing a mounted env file ==="
          set -a                     # auto-export everything assigned from here
          . /etc/app/app.env
          set +a
          echo "DEPLOY_ENV=$DEPLOY_ENV FEATURE_FLAGS=$FEATURE_FLAGS"
          echo "=== secret length only, never the value ==="
          echo "API_TOKEN length: ${#API_TOKEN}"
          sleep 3600
      env:
        # 1. Literal value
        - name: TZ
          value: "UTC"
        # 2. Kubernetes-side $(VAR) interpolation — NOT shell expansion.
        #    Only previously-defined env entries are visible; use $$( ) to escape.
        - name: API_HEALTHCHECK
          value: "$(API_ENDPOINT)/healthz"
        # 3. From a ConfigMap key
        - name: LOG_LEVEL
          valueFrom:
            configMapKeyRef:
              name: shell-demo-config
              key: LOG_LEVEL
        # 4. From a Secret key
        - name: API_TOKEN
          valueFrom:
            secretKeyRef:
              name: shell-demo-secret
              key: API_TOKEN
        # 5. Downward API — pod metadata
        - name: POD_NAME
          valueFrom:
            fieldRef:
              fieldPath: metadata.name
        - name: NODE_NAME
          valueFrom:
            fieldRef:
              fieldPath: spec.nodeName
        # 6. Downward API — resources
        - name: CPU_LIMIT_MILLICORES
          valueFrom:
            resourceFieldRef:
              containerName: shell
              resource: limits.cpu
              divisor: "1m"
      envFrom:
        # Bulk import. Keys that are not valid shell identifiers are SKIPPED
        # and reported as an event — "app.env" above is one of those.
        - configMapRef:
            name: shell-demo-config
      volumeMounts:
        - name: app-env
          mountPath: /etc/app
          readOnly: true
      resources:
        requests:
          cpu: "50m"
          memory: "64Mi"
        limits:
          cpu: "500m"
          memory: "256Mi"
      securityContext:
        allowPrivilegeEscalation: false
        readOnlyRootFilesystem: true
        capabilities:
          drop: ["ALL"]
      volumeMounts_note: null   # (remove: illustrative only)
  volumes:
    - name: app-env
      configMap:
        name: shell-demo-config
        items:
          - key: app.env
            path: app.env
```

> Quitá la línea `volumeMounts_note` antes de aplicar; se muestra para marcar dónde los lectores comúnmente duplican la clave `volumeMounts`. Las claves duplicadas en YAML son una sobrescritura silenciosa en la que gana la última en muchos parsers — `kubectl apply --validate=strict` lo detecta.

```console
$ kubectl apply -f shell-env-demo.yaml
configmap/shell-demo-config created
secret/shell-demo-secret created
pod/shell-env-demo created

$ kubectl -n platform-training logs shell-env-demo | head -20
=== argv/exec identity ===
pid=1  bashpid=1  shell=/bin/bash
=== PATH resolution ===
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
/bin/bash
/bin/cat
/usr/bin/env
=== environment (sorted) ===
API_ENDPOINT=https://api.internal.example.com
API_HEALTHCHECK=https://api.internal.example.com/healthz
API_TOKEN=s3cr3t-rotate-me
CPU_LIMIT_MILLICORES=500
HOME=/
HOSTNAME=shell-env-demo
KUBERNETES_PORT=tcp://10.96.0.1:443
...
```

Dos observaciones que son puro 103.1:

* `HOME=/` — el contenedor no tiene shell de login, ni `/etc/profile`, ni `~/.bashrc`. Las herramientas que escriben en `$HOME` intentarán escribir en `/`, que `readOnlyRootFilesystem: true` rechaza.
* `pid=1` — tu shell **es** el PID 1. Tiene que cosechar zombies y reenviar señales, o el `SIGTERM` al borrar el pod no llega a ningún lado y cada rollout tarda el `terminationGracePeriodSeconds` completo. Usá `exec` como última línea de un script de entrypoint para que el programa real reemplace al shell en lugar de ser su hijo:

```bash
#!/usr/bin/env bash
set -Eeuo pipefail
: "${API_ENDPOINT:?API_ENDPOINT must be set}"     # fail fast, with a message
exec /usr/local/bin/app --endpoint "$API_ENDPOINT"   # replaces the shell: no extra PID
```

### 7.2 systemd — sin shell, rutas absolutas, entorno explícito

```ini
# /etc/systemd/system/shell-demo.service
[Unit]
Description=103.1 environment and PATH demonstration service
Documentation=https://www.freedesktop.org/software/systemd/man/systemd.exec.html
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=appsvc
Group=appsvc
WorkingDirectory=/srv/app

# systemd does NOT read /etc/profile, ~/.bashrc, or any shell startup file.
# The default PATH is compiled in; set it explicitly if you depend on it.
Environment="PATH=/usr/local/bin:/usr/bin:/bin"
Environment="LOG_LEVEL=info" "TZ=UTC"

# EnvironmentFile syntax is NOT shell: no expansion, no command substitution,
# no `export`. A leading '-' makes a missing file non-fatal.
EnvironmentFile=-/etc/sysconfig/shell-demo
EnvironmentFile=-/run/secrets/shell-demo.env

# ExecStart requires an ABSOLUTE path. No PATH lookup, no globbing, no pipes.
ExecStart=/usr/local/bin/app --config /etc/app/config.yaml

# To use shell features you must invoke a shell explicitly and own the quoting:
# ExecStartPre=/bin/sh -c '/usr/bin/test -r /etc/app/config.yaml || exit 1'

Restart=on-failure
RestartSec=5s

# Hardening
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=strict
ProtectHome=true
ReadWritePaths=/var/lib/app /var/log/app
CapabilityBoundingSet=
AmbientCapabilities=
SystemCallFilter=@system-service
SystemCallErrorNumber=EPERM

[Install]
WantedBy=multi-user.target
```

```ini
# /etc/sysconfig/shell-demo   (EnvironmentFile format — not a shell script)
LOG_LEVEL=debug
API_ENDPOINT=https://api.internal.example.com
# WRONG — these do NOT work here:
#   export FOO=bar          -> the variable would literally be named "export FOO"
#   PATH=$PATH:/opt/bin     -> "$PATH" is stored as a literal string
#   DATE=$(date +%F)        -> stored literally as "$(date +%F)"
```

Verificá qué recibirá realmente la unidad, antes de que falle a las 03:00:

```console
$ sudo systemd-analyze verify /etc/systemd/system/shell-demo.service
$ sudo systemctl daemon-reload
$ systemctl show shell-demo.service -p Environment -p ExecStart
Environment=PATH=/usr/local/bin:/usr/bin:/bin LOG_LEVEL=info TZ=UTC
ExecStart={ path=/usr/local/bin/app ; argv[]=/usr/local/bin/app --config /etc/app/config.yaml ; ... }

$ sudo systemd-run --pty --same-dir --wait --collect \
      --unit=envprobe --property=User=appsvc /usr/bin/env
Running as unit: envprobe.service
LANG=en_US.UTF-8
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin
HOME=/var/lib/appsvc
LOGNAME=appsvc
USER=appsvc
SHELL=/bin/false
INVOCATION_ID=8f2c9a1e4d0b47f0b7c3f6a5d2e1c0b9
JOURNAL_STREAM=8:214437
```

`systemd-run` es la respuesta definitiva a *"¿qué entorno tendrá realmente este servicio?"* — es el `env -i` del mundo de systemd.

### 7.3 Imagen de contenedor — forma shell vs forma exec

```dockerfile
# syntax=docker/dockerfile:1
FROM debian:12-slim

# ARG exists only at build time; ENV persists into the image metadata and
# therefore into every container's envp[] at execve.
ARG APP_VERSION=1.4.2
ENV APP_VERSION=${APP_VERSION} \
    LOG_LEVEL=info \
    PATH="/opt/app/bin:${PATH}" \
    LANG=C.UTF-8

RUN set -Eeuo pipefail \
 && apt-get update \
 && apt-get install -y --no-install-recommends ca-certificates curl \
 && rm -rf /var/lib/apt/lists/*

WORKDIR /opt/app
COPY --chmod=0755 entrypoint.sh /opt/app/bin/entrypoint.sh

# SHELL form: run through /bin/sh -c, so $VAR, pipes and globs work,
# and the shell becomes PID 1 with the program as its child.
#   ENTRYPOINT /opt/app/bin/entrypoint.sh          <-- avoid

# EXEC form: direct execve, no shell, no expansion, signals reach the process.
ENTRYPOINT ["/opt/app/bin/entrypoint.sh"]
CMD ["--serve"]

USER 65532:65532
HEALTHCHECK --interval=30s --timeout=3s --retries=3 \
  CMD ["/usr/bin/curl", "-fsS", "http://127.0.0.1:8080/healthz"]
```

```console
$ docker build --build-arg APP_VERSION=1.5.0 -t shelldemo:1.5.0 .
$ docker run --rm -e LOG_LEVEL=debug shelldemo:1.5.0 --version
$ docker inspect -f '{{range .Config.Env}}{{println .}}{{end}}' shelldemo:1.5.0
PATH=/opt/app/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
APP_VERSION=1.5.0
LOG_LEVEL=info
LANG=C.UTF-8
```

**Nunca pongas secretos en `ENV`.** `docker inspect` y todo cliente de registro de imágenes pueden leerlos, y persisten en los metadatos de la capa de la imagen para siempre.

### 7.4 Un drop-in de `PATH` para todo el sistema, bien hecho

```sh
# /etc/profile.d/99-platform-tools.sh
# Sourced by LOGIN shells only (via /etc/profile). Must be POSIX sh — this file
# is also read by dash-based /bin/sh login shells on Debian derivatives.

platform_tools_dir=/opt/platform/bin

if [ -d "$platform_tools_dir" ]; then
    case ":${PATH}:" in
        *":${platform_tools_dir}:"*) : ;;          # already present — idempotent
        *) PATH="${platform_tools_dir}:${PATH}" ;;
    esac
    export PATH
fi
unset platform_tools_dir
```

El guard con `case` es el punto clave: sin él, cada shell de login anidado antepone el directorio otra vez, y después de un día de cadenas de `su -`/`ssh` el `PATH` tiene kilobytes de largo — lo cual, según §8.5, se come directamente tu presupuesto de `ARG_MAX`.

---

## 8. Verificación y diagnóstico de fallas

### 8.1 El árbol de decisión de `command not found` / `cannot execute`

```
Symptom
  │
  ├─ "bash: foo: command not found"                      (exit 127)
  │    ├─ type -a foo            → nothing?  it is not in PATH / not a builtin
  │    ├─ echo "$PATH"           → is the directory listed? exported?
  │    ├─ hash -r; try again     → stale hash cache?
  │    └─ ls -l /path/to/foo     → is it installed at all?  (rpm -qf / dpkg -S)
  │
  ├─ "bash: ./foo: Permission denied"                     (exit 126)
  │    ├─ ls -l ./foo            → missing the x bit?      → chmod +x
  │    ├─ findmnt -no OPTIONS -T ./foo → "noexec"?         → move it, or remount
  │    └─ ls -Z ./foo ; ausearch -m avc -ts recent → SELinux denial?
  │
  ├─ "bash: ./foo: cannot execute: required file not found"   (bash >= 5.1)
  │  "bash: ./foo: No such file or directory"                 (older bash)
  │    ├─ head -c2 ./foo == "#!" ?  → the INTERPRETER is missing
  │    │     └─ file ./foo ; sed -n 1p ./foo ; ls -l "$(sed -n '1s|^#!\([^ ]*\).*|\1|p' ./foo)"
  │    │     └─ CRLF?  file reports "with CRLF line terminators" → sed -i 's/\r$//' ./foo
  │    └─ ELF binary?              → the dynamic LOADER is missing
  │          └─ file ./foo ; ldd ./foo
  │
  └─ "bash: ./foo: cannot execute binary file: Exec format error"
       └─ wrong architecture (arm64 binary on x86_64) → file ./foo ; uname -m
```

Ejemplo trabajado — el intérprete, no el script, es lo que falta:

```console
$ ls -l ./deploy.sh
-rwxr-xr-x. 1 sre sre 412 Aug 26 11:22 ./deploy.sh

$ ./deploy.sh
bash: ./deploy.sh: /bin/bash^M: bad interpreter: No such file or directory

$ file ./deploy.sh
./deploy.sh: Bourne-Again shell script, ASCII text executable, with CRLF line terminators

$ sed -i 's/\r$//' ./deploy.sh
$ file ./deploy.sh
./deploy.sh: Bourne-Again shell script, ASCII text executable
$ ./deploy.sh
deploying...
```

Ejemplo trabajado — el loader ELF:

```console
$ ./app
bash: ./app: cannot execute: required file not found

$ file ./app
./app: ELF 64-bit LSB pie executable, x86-64, dynamically linked,
interpreter /lib/ld-musl-x86_64.so.1, stripped

$ ls -l /lib/ld-musl-x86_64.so.1
ls: cannot access '/lib/ld-musl-x86_64.so.1': No such file or directory
```

El binario fue compilado contra musl (una imagen de Alpine) y copiado a un host con glibc. `execve` devolvió `ENOENT` por el *intérprete*, y bash lo reportó contra el nombre de tu archivo. `file` + `ldd` desambiguan en dos segundos; adivinar no.

### 8.2 `strace`: mirá cómo ocurren el `execve` y la búsqueda en `PATH`

```console
$ strace -f -e trace=execve,access -qq -o /tmp/tr.log bash -c 'kubectl version --client' 
$ grep -E 'execve' /tmp/tr.log
execve("/bin/bash", ["bash", "-c", "kubectl version --client"], 0x7ffd1c2a1e30 /* 34 vars */) = 0
execve("/home/sre/.local/bin/kubectl", ["kubectl", "version", "--client"], 0x55d3f2a1c8b0 /* 34 vars */) = -1 ENOENT (No such file or directory)
execve("/usr/local/bin/kubectl", ["kubectl", "version", "--client"], 0x55d3f2a1c8b0 /* 34 vars */) = -1 ENOENT (No such file or directory)
execve("/usr/bin/kubectl", ["kubectl", "version", "--client"], 0x55d3f2a1c8b0 /* 34 vars */) = 0
```

Estás literalmente viendo el recorrido de `PATH`, de izquierda a derecha, con un `ENOENT` por cada fallo. La anotación `/* 34 vars */` es el tamaño de tu `envp[]`. Este único comando zanja definitivamente las discusiones sobre "¿es un problema de PATH o de permisos?".

### 8.3 `set -x`: ver los resultados de la expansión, no tus intenciones

```console
$ cat check.sh
#!/usr/bin/env bash
set -Eeuo pipefail
TARGET=${1:-/var/log}
FILES=$(find "$TARGET" -name '*.log' -mtime +7)
echo "would remove: $FILES"

$ bash -x ./check.sh '/var/log/my app'
+ TARGET='/var/log/my app'
++ find '/var/log/my app' -name '*.log' -mtime +7
+ FILES='/var/log/my app/old.log
/var/log/my app/older.log'
+ echo 'would remove: /var/log/my app/old.log
/var/log/my app/older.log'
would remove: /var/log/my app/old.log
/var/log/my app/older.log
```

`+` es un nivel de expansión, `++` es uno anidado (`PS4` controla el prefijo). Hacé que el trace sea mucho más útil:

```console
$ export PS4='+ ${BASH_SOURCE##*/}:${LINENO}:${FUNCNAME[0]:-main}: '
$ bash -x ./check.sh /var/log
+ check.sh:3:main: TARGET=/var/log
+ check.sh:4:main: find /var/log -name '*.log' -mtime +7
```

Trazá solo una sección crítica en lugar del script completo:

```bash
set -x
critical_step "$@"
set +x
```

### 8.4 Comparar dos entornos — la resolución de "funciona en mi shell"

```console
$ env -i bash --noprofile --norc -c 'env' | sort > /tmp/env.minimal
$ env | sort > /tmp/env.interactive
$ diff /tmp/env.minimal /tmp/env.interactive | head -12
1a2,10
> AWS_PROFILE=platform-admin
> KUBECONFIG=/home/sre/.kube/config-prod
> LANG=en_US.UTF-8
> PATH=/home/sre/.local/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin
> PYENV_ROOT=/home/sre/.pyenv
> SSH_AUTH_SOCK=/run/user/1000/keyring/ssh
```

Cada línea de ese diff es una dependencia oculta que tu script tiene con tu estación de trabajo. `KUBECONFIG` y `SSH_AUTH_SOCK` en particular son la razón de "el script desplegó a producción desde mi laptop pero no hace nada desde el runner".

La misma técnica contra un proceso vivo, para daemons que no arrancaste vos:

```console
$ pidof nginx
2841 2840 2839
$ sudo tr '\0' '\n' < /proc/2839/environ | sort
LANG=en_US.UTF-8
NGINX_BINARY=/usr/sbin/nginx
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin
```

### 8.5 `Argument list too long` (`E2BIG`)

```console
$ ls /var/log/archive | wc -l
412093
$ rm -f /var/log/archive/*.gz
bash: /usr/bin/rm: Argument list too long

$ getconf ARG_MAX
2097152

$ ulimit -s
8192

$ xargs --show-limits < /dev/null
Your environment variables take up 4283 bytes
POSIX upper limit on argument length (this system): 2090821
POSIX smallest allowable upper limit on argument length (all systems): 4096
Maximum length of command we could actually use: 2086538
Size of command buffer we are actually using: 131072
Maximum parallelism (--max-procs must be no greater than): 2147483647
```

Fijate en la primera línea: **tu entorno se carga contra el mismo presupuesto que tus argumentos.** Un `PATH` inflado (§7.4) o una variable exportada grande reducen de forma medible cuántos nombres de archivo podés pasar. Soluciones correctas, en orden de preferencia:

```console
$ find /var/log/archive -maxdepth 1 -name '*.gz' -delete
$ find /var/log/archive -maxdepth 1 -name '*.gz' -print0 | xargs -0 -r rm -f
$ find /var/log/archive -maxdepth 1 -name '*.gz' -exec rm -f {} +
```

`-print0`/`-0` es separación por NUL, inmune a espacios y saltos de línea en los nombres de archivo. `-r` (`--no-run-if-empty`) evita que `xargs` ejecute `rm` sin argumentos. `-exec … +` agrupa por lotes, `-exec … \;` hace un fork por archivo — con 400k archivos la diferencia es medible:

```console
$ time find /var/log/archive -name '*.gz' -exec stat -c %s {} \; > /dev/null
real    3m41.207s
$ time find /var/log/archive -name '*.gz' -exec stat -c %s {} + > /dev/null
real    0m4.882s
```

Notá también que `time` acá es la **palabra clave** de bash (cronometra el pipeline completo), no `/usr/bin/time`. `type -a time` muestra ambos.

### 8.6 Identificación del sistema: `uname`

```console
$ uname -a
Linux prod-worker-03 6.1.0-27-amd64 #1 SMP PREEMPT_DYNAMIC Debian 6.1.115-1 (2026-07-14) x86_64 GNU/Linux
```

| Flag | Campo | Valor de arriba | Uso típico |
|---|---|---|---|
| `-s` | nombre del kernel | `Linux` | ramificación por portabilidad en scripts |
| `-n` | nombre de nodo | `prod-worker-03` | preferí `hostnamectl`/`hostname -f` para el FQDN |
| `-r` | **release** del kernel | `6.1.0-27-amd64` | aplicabilidad de CVE, coincidencia de módulos/drivers, `/lib/modules/$(uname -r)` |
| `-v` | **versión** del kernel (cadena de build) | `#1 SMP … Debian 6.1.115-1` | identificar el build exacto del kernel de la distro |
| `-m` | hardware de la máquina | `x86_64` | descargas específicas de arquitectura |
| `-o` | sistema operativo (ext. GNU) | `GNU/Linux` | |
| `-p`, `-i` | procesador, plataforma de hardware | a menudo `unknown` en Linux | rara vez útiles; no dependas de ellos |

```console
$ uname -r
6.1.0-27-amd64
$ ls /lib/modules/$(uname -r)/kernel/net/ | head -3
802
8021q
bridge
$ cat /etc/os-release | head -3
PRETTY_NAME="Debian GNU/Linux 12 (bookworm)"
NAME="Debian GNU/Linux"
VERSION_ID="12"
```

**`uname` describe el kernel, `/etc/os-release` describe la distribución.** Un contenedor que corre `debian:12-slim` sobre un host Fedora reporta el kernel *del host* con `uname -r` y Debian desde `/etc/os-release` — porque los contenedores comparten el kernel del host. Confundir estos dos produce reportes de vulnerabilidades incorrectos:

```console
$ docker run --rm debian:12-slim sh -c 'uname -r; head -1 /etc/os-release'
7.1.8-200.fc44.x86_64
PRETTY_NAME="Debian GNU/Linux 12 (bookworm)"
```

### 8.7 Obtener documentación en la propia máquina, sin conexión

```console
$ man 5 crontab            # section 5 = file formats, NOT the crontab command
$ man -f printf
printf (1)           - format and print data
printf (3)           - formatted output conversion
printf (1p)          - write formatted output

$ apropos -s 1 'shell'
bash (1)             - GNU Bourne-Again SHell
dash (1)             - command interpreter (shell)
sh (1)               - command interpreter (shell)

$ man -k 'environment' | head -3
env (1)              - run a program in a modified environment
environ (7)          - user environment
printenv (1)         - print environment variables

$ help export         # BUILTINS are documented by `help`, not by man
export: export [-fn] [name[=value] ...] or export -p
    Set export attribute for shell variables.
    ...
```

| Sección | Contenido | Ejemplo |
|---|---|---|
| 1 | Comandos de usuario | `man 1 echo` |
| 2 | Llamadas al sistema | `man 2 execve` |
| 3 | Funciones de biblioteca | `man 3 getenv` |
| 4 | Dispositivos, archivos especiales | `man 4 null` |
| 5 | Formatos de archivo, configuración | `man 5 crontab`, `man 5 sudoers` |
| 6 | Juegos | |
| 7 | Misceláneos, convenciones, panoramas | `man 7 environ`, `man 7 signal` |
| 8 | Administración del sistema | `man 8 mount` |

`man -a printf` recorre cada sección por turno. Si `man -k` devuelve `nothing appropriate`, falta el índice — ejecutá `sudo mandb` (Debian) o `sudo makewhatis`/`mandb` (RHEL). En imágenes de contenedor mínimas las páginas de manual se eliminan por completo; eso es un compromiso deliberado de tamaño, y la respuesta es `--help` más una fuente de documentación fuera de la imagen.

**La trampa:** para `echo`, `pwd`, `test`, `kill` y `time`, `man` documenta el binario **externo** de coreutils mientras que tu shell ejecuta el **builtin**, y difieren. `echo -e` funciona en el builtin de bash y en GNU coreutils, pero no en el builtin de `dash` ni bajo `sh` en modo POSIX. `printf` es la opción portable:

```console
$ type -a echo
echo is a shell builtin
echo is /usr/bin/echo

$ printf '%s\t%s\n' col1 col2      # portable, predictable, no -e/-n guessing
col1	col2
```

### 8.8 Un script reutilizable de sondeo del entorno

```bash
#!/usr/bin/env bash
# env-probe.sh — capture everything 103.1 governs, for a bug report.
set -Eeuo pipefail

printf '=== identity ===\n'
printf 'user=%s uid=%s pid=%s ppid=%s\n' "$(id -un)" "$(id -u)" "$$" "$PPID"
printf 'shell=%s version=%s\n' "${SHELL:-unset}" "${BASH_VERSION:-not-bash}"
printf 'login_shell=%s interactive=%s\n' \
       "$(shopt -q login_shell && echo yes || echo no)" \
       "$([[ $- == *i* ]] && echo yes || echo no)"
printf 'cwd=%s\n' "$PWD"

printf '\n=== system ===\n'
uname -srvmo
[[ -r /etc/os-release ]] && grep -E '^(PRETTY_NAME|VERSION_ID)=' /etc/os-release

printf '\n=== PATH (one entry per line, marking problems) ===\n'
IFS=':' read -ra path_entries <<< "$PATH"
for entry in "${path_entries[@]}"; do
    if   [[ -z $entry   ]]; then printf '  !! EMPTY  (means ".", insecure)\n'
    elif [[ $entry == . ]]; then printf '  !! "."    (insecure)\n'
    elif [[ ! -d $entry ]]; then printf '  ?  %s (does not exist)\n' "$entry"
    elif [[ -w $entry && ! -O $entry ]]; then
                                 printf '  !! %s (writable, not owned by you)\n' "$entry"
    else                         printf '  ok %s\n' "$entry"
    fi
done

printf '\n=== command resolution ===\n'
for cmd in "$@"; do
    if type -a "$cmd" 2>/dev/null; then :; else printf '%s: NOT FOUND\n' "$cmd"; fi
done

printf '\n=== hash cache ===\n'
hash -l 2>/dev/null || printf '(empty)\n'

printf '\n=== environment (values of sensitive names redacted) ===\n'
env | sort | sed -E 's/^([^=]*(TOKEN|SECRET|PASSWORD|KEY)[^=]*)=.*/\1=<redacted>/'

printf '\n=== shell options ===\n'
printf 'set: %s\n' "$-"
shopt | grep -E '^(histappend|expand_aliases|checkwinsize|globstar|nullglob)\s'
```

```console
$ ./env-probe.sh kubectl helm terraform
=== identity ===
user=sre uid=1000 pid=12043 ppid=12042
shell=/bin/bash version=5.2.15(1)-release
login_shell=no interactive=no
cwd=/home/sre

=== system ===
Linux 6.1.0-27-amd64 #1 SMP PREEMPT_DYNAMIC Debian 6.1.115-1 (2026-07-14) x86_64 GNU/Linux
PRETTY_NAME="Debian GNU/Linux 12 (bookworm)"
VERSION_ID="12"

=== PATH (one entry per line, marking problems) ===
  ok /home/sre/.local/bin
  ok /usr/local/bin
  ok /usr/bin
  ok /bin
  ?  /opt/legacy/bin (does not exist)
  !! EMPTY  (means ".", insecure)

=== command resolution ===
kubectl is /usr/bin/kubectl
helm is /usr/local/bin/helm
terraform: NOT FOUND
...
```

Adjuntá esa salida al ticket y la conversación de "en mi máquina funciona" se termina en un solo intercambio.

---

## 9. Ejercicios enfocados en el examen

Respondé antes de verificar; cada uno se corresponde con un mecanismo específico de más arriba.

1. `VAR=x bash -c 'echo $VAR'` imprime `x`, pero `VAR=x; bash -c 'echo $VAR'` imprime una línea vacía. ¿Por qué?
   *Una asignación como prefijo en la línea de comandos coloca la variable en el entorno de ese comando solo para esa invocación. Una asignación simple crea una variable del shell no exportada.*
2. ¿Por qué `cd /tmp | cat` te deja en tu directorio original?
   *Cada etapa de un pipeline corre en un subshell; `cd` es un builtin que actúa sobre ese hijo de vida corta.*
3. `echo $PATH` y `sudo echo $PATH` imprimen la misma cadena. ¿Por qué eso no es evidencia de que `sudo` preserva `PATH`?
   *El shell padre expande `$PATH` **antes** del `execve`, así que `sudo` recibe el literal ya expandido. Usá `sudo printenv PATH` o `sudo sh -c 'echo $PATH'`.*
4. Un archivo es `-rwxr-xr-x`, está en `PATH`, y `./file` sigue dando `command not found`.
   *`command not found` significa que falló la búsqueda en `PATH`; con `./` no hay búsqueda, así que el mensaje debe ser otro. Si realmente es `command not found`, un alias o una entrada de `hash -p` está interceptando el nombre — verificá con `type -a`.*
5. ¿Qué hace `PATH=/usr/bin:` que no hace `PATH=/usr/bin`?
   *Agrega el directorio actual como una ubicación de búsqueda, mediante el campo vacío al final.*
6. `history` muestra un comando que está ausente de `~/.bash_history`. Dá dos explicaciones.
   *Todavía no fue volcado (sin `history -a`, el shell sigue corriendo), o `HISTCONTROL`/`HISTIGNORE` lo excluyeron del archivo mientras permanece en memoria.*
7. ¿Cuál es la diferencia entre `echo "$@"` y `echo "$*"` cuando el script es invocado con `a "b c"`?
   *`"$@"` produce dos palabras `a` y `b c`; `"$*"` produce una sola palabra `a b c` unida por el primer carácter de `IFS`.*
8. `find . -name *.log` falla con `paths must precede expression`. ¿Por qué, y cuál es el arreglo?
   *El shell expandió el glob `*.log` contra el directorio actual antes de que `find` se ejecutara. Entrecomillalo: `-name '*.log'`.*
9. ¿Cómo ejecutás el `ls` del sistema cuando existe una función llamada `ls`?
   *`command ls`, `\ls` (esquiva solo los aliases), o `/usr/bin/ls`.*
10. ¿Por qué `ExecStart=` en una unidad de systemd tiene que ser una ruta absoluta?
    *systemd llama a `execve` directamente sin ningún shell y no realiza búsqueda propia en `PATH` para el token inicial.*

---

## 10. Referencias

**Objetivos de la certificación**
- LPI — Objetivos del examen 101-500 (Tema 103.1): https://www.lpi.org/our-certifications/exam-101-objectives/
- LPI — Panorama de la certificación LPIC-1: https://www.lpi.org/our-certifications/lpic-1-overview/
- LPI — Objetivos del examen 102-500: https://www.lpi.org/our-certifications/exam-102-objectives/

**Shell y estándares**
- GNU Bash Reference Manual: https://www.gnu.org/software/bash/manual/bash.html
- GNU Bash — Shell Expansions: https://www.gnu.org/software/bash/manual/html_node/Shell-Expansions.html
- GNU Bash — Bash History Facilities: https://www.gnu.org/software/bash/manual/html_node/Bash-History-Facilities.html
- GNU Bash — History Interaction (expansión con `!`): https://www.gnu.org/software/bash/manual/html_node/History-Interaction.html
- GNU Bash — The Set Builtin: https://www.gnu.org/software/bash/manual/html_node/The-Set-Builtin.html
- POSIX.1-2024 — Shell Command Language: https://pubs.opengroup.org/onlinepubs/9799919799/utilities/V3_chap02.html
- POSIX.1-2024 — Environment Variables: https://pubs.opengroup.org/onlinepubs/9799919799/basedefs/V1_chap08.html
- GNU Coreutils Manual (`env`, `printenv`, `echo`, `printf`, `pwd`, `uname`): https://www.gnu.org/software/coreutils/manual/coreutils.html

**Kernel e interfaces del sistema**
- `execve(2)` — incluyendo los límites `E2BIG` / `MAX_ARG_STRLEN`: https://man7.org/linux/man-pages/man2/execve.2.html
- `environ(7)`: https://man7.org/linux/man-pages/man7/environ.7.html
- `proc(5)` — `/proc/[pid]/environ`, `/proc/[pid]/cmdline`: https://man7.org/linux/man-pages/man5/proc.5.html
- `fork(2)`: https://man7.org/linux/man-pages/man2/fork.2.html
- `bash(1)`: https://man7.org/linux/man-pages/man1/bash.1.html
- `xargs(1)`: https://man7.org/linux/man-pages/man1/xargs.1.html
- `find(1)` — manual de GNU findutils: https://www.gnu.org/software/findutils/manual/html_mono/find.html
- `uname(1)`: https://man7.org/linux/man-pages/man1/uname.1.html
- `man(1)` y las secciones del manual: https://man7.org/linux/man-pages/man1/man.1.html

**Entornos de privilegios y servicios**
- `sudoers(5)` — `env_reset`, `secure_path`, `env_keep`: https://www.sudo.ws/docs/man/sudoers.man/
- `sudo(8)` — el entorno del comando: https://www.sudo.ws/docs/man/sudo.man/
- `systemd.exec(5)` — `Environment=`, `EnvironmentFile=`, `$PATH` por defecto: https://www.freedesktop.org/software/systemd/man/latest/systemd.exec.html
- `systemd.service(5)` — parseo de la línea de comandos de `ExecStart=`: https://www.freedesktop.org/software/systemd/man/latest/systemd.service.html
- `systemd-run(1)`: https://www.freedesktop.org/software/systemd/man/latest/systemd-run.html
- `crontab(5)` — el entorno de cron: https://man7.org/linux/man-pages/man5/crontab.5.html

**Entornos de contenedores y orquestación**
- Kubernetes — Define Environment Variables for a Container: https://kubernetes.io/docs/tasks/inject-data-application/define-environment-variable-container/
- Kubernetes — Define a Command and Arguments for a Container: https://kubernetes.io/docs/tasks/inject-data-application/define-command-argument-container/
- Kubernetes — Expose Pod Information to Containers (Downward API): https://kubernetes.io/docs/tasks/inject-data-application/environment-variable-expose-pod-information/
- Kubernetes — Distribute Credentials Securely Using Secrets: https://kubernetes.io/docs/tasks/inject-data-application/distribute-credentials-secure/
- Docker — Dockerfile reference (`ENV`, `ARG`, `ENTRYPOINT` forma shell vs exec): https://docs.docker.com/reference/dockerfile/
- Filesystem Hierarchy Standard 3.0 (`/bin`, `/usr/bin`, `/sbin`, `/usr/local/bin`): https://refspecs.linuxfoundation.org/FHS_3.0/fhs/index.html