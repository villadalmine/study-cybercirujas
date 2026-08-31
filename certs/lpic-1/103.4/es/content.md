# 103.4 — Uso de flujos, tuberías y redirecciones

**Certificación:** LPIC-1 (Exámenes 101-500 / 102-500, versión 5.0)
**Tema:** 103.4 — Uso de flujos, tuberías y redirecciones
**Peso en el examen:** 6.25
**Nivel:** Avanzado — perfil SRE / Arquitecto de Plataforma

**Áreas de conocimiento clave cubiertas por el objetivo:** redirigir la entrada estándar, la salida estándar y el error estándar; canalizar la salida de un comando hacia la entrada de otro; usar la salida de un comando como argumentos de otro comando; enviar la salida simultáneamente a stdout y a un archivo.

**Términos y utilidades:** `tee`, `xargs`, y los operadores del shell `<`, `>`, `>>`, `|`, `2>`, `2>&1`, `&>`, `<<`, `<<<`, `<()`, `>()`.

---

## 1. Motivación y el problema arquitectónico en producción

### 1.1 Por qué una abstracción de los años 70 sigue siendo el muro portante de tu plataforma

El modelo de flujos de Unix establece que un proceso no tiene idea de *con qué* está hablando. Escribe bytes en un entero pequeño. Que ese entero resuelva a una terminal, a un archivo regular sobre XFS, a una tubería hacia `gzip`, a un socket UNIX consumido por `journald` o a un dispositivo `null` lo decide **quien lo invoca, después de que el programa fue compilado**. Este enlace tardío es la razón por la cual una imagen de contenedor construida en 2019 puede ser observada por un pipeline de logs diseñado en 2026 sin recompilación.

Todo contrato de plataforma moderno que operás depende de esto:

| Contrato de plataforma | Qué le exige realmente al proceso | Modo de falla cuando se viola |
|---|---|---|
| **Twelve-Factor App XI (Logs)** | Escribir un flujo de eventos sin búfer a `stdout`; nunca gestionar archivos ni rotación | La app escribe en `/var/log/app.log` dentro de un contenedor efímero → los logs mueren con el pod |
| **Drivers de log `json-file` / `local` de Docker** | El runtime adjunta una tubería al fd 1 y al fd 2 del PID 1 del contenedor | La app se demoniza y cierra los fds → `docker logs` queda vacío para siempre |
| **`kubectl logs` de Kubernetes** | El kubelet lee archivos en formato CRI alimentados desde las tuberías de stdout/stderr del contenedor | La app hace fork de un hijo que no hereda nada → logs parciales o ausentes |
| **`StandardOutput=journal` de systemd** | El fd 1 y el fd 2 de la unidad son sockets `AF_UNIX` hacia `systemd-journald` | La unidad usa `ExecStart=/bin/sh -c 'app > /var/log/app.log'` → el journal no tiene nada, `journalctl -u` es inútil durante un incidente |
| **Logs de trabajos CI/CD** | El runner adjunta un pty o una tubería y la transmite | Búfer completo sobre una tubería → el trabajo parece colgado durante 4 minutos y después vuelca 4 MiB de golpe |

### 1.2 Tres incidentes reales que este objetivo previene

**Incidente A — El backup que nunca falló.**

```bash
pg_dump production | gzip > /backup/prod-$(date +%F).sql.gz
```

`pg_dump` murió con `FATAL: terminating connection due to administrator command`. `gzip` comprimió alegremente los 0 bytes que recibió y salió con 0. El estado de salida de la tubería es el estado de salida del **último** comando, así que el script envoltorio registró `backup OK`, el chequeo de monitoreo se puso en verde, y los archivos gzip de 214 bytes recién se descubrieron once semanas después durante un simulacro de restauración. La solución es una línea — `set -o pipefail` — y es material examinable.

**Incidente B — El servicio que "se colgaba" al arrancar.**

Un servicio Python funcionaba bien de forma interactiva pero no producía salida durante minutos bajo systemd. No había nada mal en el servicio: el stdio de glibc cambia el fd 1 de **búfer por líneas** a **búfer completo (4 KiB)** cuando no es una TTY. Bajo systemd, el fd 1 es un socket. Los logs existían; estaban sentados en memoria de espacio de usuario. Durante el incidente, el ingeniero de guardia reinició el proceso, descartando el búfer y la evidencia.

**Incidente C — El disco que estaba lleno pero vacío.**

`df` reportaba 100% en `/var`; `du -sh /var` reportaba 3 GB de 200 GB. Un script de rotación de logs había hecho `rm` de un archivo de 180 GB mientras la aplicación todavía mantenía el fd 3 abierto sobre él. El contador de enlaces del inodo llegó a cero, pero la **descripción de archivo abierto** lo mantuvo vivo. El espacio se recuperó recién cuando se reinició el proceso — o, como el equipo terminó aprendiendo, truncando a través de `/proc/<pid>/fd/3`.

Los tres son el mismo tema: **descriptores de archivo, su ciclo de vida y su semántica de buffering**.

---

## 2. El modelo del kernel: descriptores, descripciones e inodos

No se puede razonar correctamente sobre redirección sin tres objetos distintos. Confundirlos produce exactamente los bugs de la sección 9.

```
   Process (PID 4711)                Kernel                     Filesystem
 ┌─────────────────────┐    ┌───────────────────────────┐    ┌──────────────┐
 │ fd table (per proc) │    │ open file description     │    │ inode        │
 │  0 ──────────────┐  │    │  table (system-wide)      │    │  (per file)  │
 │  1 ────────────┐ │  │    │                           │    │              │
 │  2 ──────────┐ │ │  │    │ ┌───────────────────────┐ │    │ ┌──────────┐ │
 │  3 ────────┐ │ │ └──┼───▶│ │ offset, O_APPEND,     │─┼───▶│ │ 8:2 ino  │ │
 │            │ │ └────┼───▶│ │ O_NONBLOCK, access    │ │    │ │ 1441795  │ │
 │            │ └──────┼───▶│ │ mode, refcount        │ │    │ │ nlink=1  │ │
 │            └────────┼───▶│ └───────────────────────┘ │    │ └──────────┘ │
 └─────────────────────┘    └───────────────────────────┘    └──────────────┘
```

* **Descriptor de archivo (fd)** — un índice entero por proceso. `dup2(3, 1)` hace que el índice 1 apunte a lo que sea que apunte el índice 3. Esto es *literalmente* lo que hace el shell en cada redirección.
* **Descripción de archivo abierto** — el objeto del kernel que contiene el **desplazamiento (offset)** del archivo y las banderas de estado. Dos fds creados por dos llamadas `open()` separadas sobre la misma ruta tienen **offsets independientes**. Dos fds creados por `dup()`/`dup2()` **comparten** un offset. Esta única distinción explica por qué `cmd > f 2> f` corrompe datos y `cmd > f 2>&1` no.
* **Inodo** — el archivo en disco. Se libera cuando `nlink == 0` **y** ninguna descripción de archivo abierto lo referencia. De ahí el incidente C.

### 2.1 Los tres flujos estándar

| fd | Nombre POSIX | Manejador stdio de C | Buffering por defecto en TTY | Por defecto en tubería/archivo | Uso convencional |
|---:|---|---|---|---|---|
| 0 | entrada estándar | `stdin` | búfer por líneas | búfer completo | datos a consumir |
| 1 | salida estándar | `stdout` | búfer por líneas | **búfer completo (4 KiB+)** | el *resultado* — parseable por máquina |
| 2 | error estándar | `stderr` | sin búfer | **sin búfer** | diagnósticos, progreso, prompts |

> **Regla arquitectónica:** el fd 1 transporta la carga útil del programa; el fd 2 transporta comentarios *sobre* el programa. Una herramienta que imprime barras de progreso en el fd 1 no se puede canalizar y por lo tanto es inutilizable en automatización. Por eso `curl` escribe su medidor de transferencia en el fd 2, y por eso las advertencias de `kubectl get -o json` van al fd 2.

Los descriptores 3 y superiores son tuyos. Nada en el kernel privilegia al 0/1/2; la convención la imponen enteramente libc y el shell.

### 2.2 Observando el modelo directamente

```bash
$ sleep 300 > /tmp/out.log 2>&1 < /dev/null &
[1] 4711
$ ls -l /proc/4711/fd
total 0
lr-x------. 1 dalmine dalmine 64 Aug 26 14:02 0 -> /dev/null
l-wx------. 1 dalmine dalmine 64 Aug 26 14:02 1 -> /tmp/out.log
l-wx------. 1 dalmine dalmine 64 Aug 26 14:02 2 -> /tmp/out.log
```

```bash
$ cat /proc/4711/fdinfo/1
pos:	0
flags:	02101001
mnt_id:	28
ino:	1441795
$ cat /proc/4711/fdinfo/2
pos:	0
flags:	02101001
mnt_id:	28
ino:	1441795
```

`ino` idéntico, y como `2>&1` fue un `dup2`, son la **misma** descripción de archivo abierto: avanzar una avanza la otra. Compará con `> /tmp/out.log 2> /tmp/out.log`, que produce dos descripciones que ambas arrancan en `pos: 0`.

Las rutas `/dev/std*` son solamente una vista desde espacio de usuario de la misma tabla:

```bash
$ ls -l /dev/stdin /dev/stdout /dev/stderr /dev/fd
lrwxrwxrwx. 1 root root 15 Aug 26 09:11 /dev/fd -> /proc/self/fd
lrwxrwxrwx. 1 root root 15 Aug 26 09:11 /dev/stderr -> /proc/self/fd/2
lrwxrwxrwx. 1 root root 15 Aug 26 09:11 /dev/stdin -> /proc/self/fd/0
lrwxrwxrwx. 1 root root 15 Aug 26 09:11 /dev/stdout -> /proc/self/fd/1
```

---

## 3. Redirección: referencia completa de operadores y compromisos

### 3.1 La matriz de operadores

`n` es un número de fd opcional inmediatamente antes del operador (**sin espacio**), que por defecto es 0 para entrada y 1 para salida.

| Operador | `sh` POSIX | bash | Efecto de la llamada al sistema subyacente | Semántica |
|---|:---:|:---:|---|---|
| `n> file` | ✅ | ✅ | `open(O_WRONLY\|O_CREAT\|O_TRUNC)` + `dup2` | Trunca/crea, escribe |
| `n>> file` | ✅ | ✅ | `open(O_WRONLY\|O_CREAT\|O_APPEND)` | Añade; cada `write()` es atómico respecto del offset |
| `n< file` | ✅ | ✅ | `open(O_RDONLY)` | Lee |
| `n<> file` | ✅ | ✅ | `open(O_RDWR\|O_CREAT)` | Lectura-escritura, **sin truncar** |
| `n>| file` | ✅ | ✅ | `open(...O_TRUNC)` | Fuerza el truncado incluso con `set -o noclobber` |
| `n>&m` | ✅ | ✅ | `dup2(m, n)` | Apunta el fd *n* a la descripción del fd *m* |
| `n<&m` | ✅ | ✅ | `dup2(m, n)` | Ídem, del lado de la entrada |
| `n>&-` / `n<&-` | ✅ | ✅ | `close(n)` | Cierra el descriptor |
| `&> file` | ❌ | ✅ | `dup2` después de `open` | Atajo para `> file 2>&1` |
| `&>> file` | ❌ | ✅ | — | Atajo para `>> file 2>&1` |
| `<< DELIM` | ✅ | ✅ | archivo temporal o tubería en el fd 0 | Here-document |
| `<<- DELIM` | ✅ | ✅ | — | Here-document, elimina **solo tabuladores iniciales** |
| `<<< word` | ❌ | ✅ (también ksh/zsh) | — | Here-string |
| `<(cmd)` / `>(cmd)` | ❌ | ✅ (también ksh/zsh) | `pipe2()` + `/dev/fd/N` | Sustitución de procesos — se expande a un *nombre de ruta* |
| `\|&` | ❌ | ✅ (bash 4+) | — | Atajo para `2>&1 \|` |
| `{var}> file` | ❌ | ✅ (bash 4.1+) | — | Asigna un fd libre ≥ 10 en `$var` |

### 3.2 Orden: la sutileza más evaluada de todas

Las redirecciones se procesan **de izquierda a derecha**, y `n>&m` copia el destino *actual* de `m`.

```bash
$ ls /etc/hostname /etc/nope > /tmp/a.txt 2>&1 ; cat /tmp/a.txt
ls: cannot access '/etc/nope': No such file or directory
/etc/hostname
```

```bash
$ ls /etc/hostname /etc/nope 2>&1 > /tmp/b.txt
ls: cannot access '/etc/nope': No such file or directory
$ cat /tmp/b.txt
/etc/hostname
```

En el segundo caso, en el momento en que se evaluó `2>&1`, el fd 1 todavía se refería a la terminal, así que el fd 2 quedó apuntando a la terminal. Recién después el fd 1 fue movido al archivo. La regla mnemotécnica: **`2>&1` significa "adonde apunta 1 *ahora mismo*", no "adonde 1 va a apuntar eventualmente".**

El intercambio idiomático de stdout y stderr usa la misma regla más un descriptor auxiliar:

```bash
$ { ls /etc/hostname /etc/nope 3>&2 2>&1 1>&3 3>&- ; } | sed 's/^/[stdout-channel] /'
[stdout-channel] ls: cannot access '/etc/nope': No such file or directory
/etc/hostname
```

### 3.3 El truncado ocurre *antes* de que corra el comando

El shell realiza todas las redirecciones después del fork y antes de `execve`. Por lo tanto:

```bash
$ printf 'c\na\nb\n' > /tmp/data.txt
$ sort /tmp/data.txt > /tmp/data.txt
$ wc -c /tmp/data.txt
0 /tmp/data.txt
```

El archivo fue truncado a cero antes de que `sort` siquiera lo abriera. **Nunca redirijas hacia un archivo que también es una entrada.** Alternativas seguras para producción:

| Enfoque | Comando | ¿Atómico? | Notas |
|---|---|:---:|---|
| Archivo temporal + renombrado | `sort f > f.tmp && mv f.tmp f` | ✅ en el mismo sistema de archivos | `rename(2)` es atómico; preserva a los lectores del inodo viejo |
| `sponge` (moreutils) | `sort f \| sponge f` | ⚠️ | Almacena toda la entrada en memoria y después escribe; no es atómico, pero evita el truncado |
| Bandera in-place | `sed -i`, `perl -i`, `sort -o f f` | Varía | `sort -o` lo soporta explícitamente; `sed -i` crea un inodo nuevo (rompe hardlinks y fds abiertos) |
| `<>` lectura-escritura | `exec 3<> f` | ❌ | Avanzado; sin truncado, vos gestionás los offsets |

`sort` es la excepción que vale la pena memorizar:

```bash
$ printf 'c\na\nb\n' > /tmp/data.txt
$ sort -o /tmp/data.txt /tmp/data.txt
$ cat /tmp/data.txt
a
b
c
```

### 3.4 `noclobber` — una barandilla barata para shells root interactivos

```bash
$ set -o noclobber
$ echo hello > /tmp/data.txt
-bash: /tmp/data.txt: cannot overwrite existing file
$ echo hello >| /tmp/data.txt
$ echo more >> /tmp/data.txt
```

`noclobber` protege solamente contra `>`. **No** protege contra `>>`, `dd of=`, `cp` ni `tee`. Tratalo como ergonomía, no como un control.

### 3.5 Redirección persistente con `exec`

`exec` **sin un comando** aplica las redirecciones al shell actual, de forma permanente. Así se construye un script que registra todo lo que hace sin envolver cada línea.

```bash
#!/usr/bin/env bash
set -Eeuo pipefail

readonly LOGFILE=/var/log/deploy.log

# Duplicate the original terminal onto fd 3 so we can still talk to the operator.
exec 3>&1 4>&2
# Everything from here on goes to the log AND to the original stdout.
exec > >(tee -a "$LOGFILE") 2>&1

echo "starting deploy"          # -> terminal + logfile
echo "operator-only note" >&3   # -> terminal only
```

Cerrar descriptores es igual de explícito e importa cuando lanzás hijos que no deben heredar un lock o un socket:

```bash
$ exec 9> /var/lock/deploy.lock
$ flock -n 9 || { echo "another deploy is running" >&2; exit 1; }
$ ls -l /proc/$$/fd/9
l-wx------. 1 dalmine dalmine 64 Aug 26 14:31 /proc/29144/fd/9 -> /var/lock/deploy.lock
$ exec 9>&-
$ ls -l /proc/$$/fd/9
ls: cannot access '/proc/29144/fd/9': No such file or directory
```

La asignación automática de descriptores evita fijar números que pueden colisionar en bibliotecas incluidas con `source`:

```bash
$ exec {audit_fd}>>/var/log/audit-trail.log
$ echo "fd allocated: $audit_fd"
fd allocated: 10
$ printf '%s deploy started\n' "$(date -Is)" >&"$audit_fd"
$ exec {audit_fd}>&-
```

### 3.6 Here-documents, here-strings y sustitución de procesos

```bash
$ cat <<'EOF' > /etc/sysctl.d/99-platform.conf
# $HOME and `hostname` are NOT expanded because the delimiter is quoted
net.core.somaxconn = 4096
net.ipv4.tcp_tw_reuse = 1
fs.file-max = 2097152
EOF
```

| Forma | Expansión de `$var`, `` `cmd` ``, `\` | Uso típico |
|---|:---:|---|
| `<< EOF` | ✅ | Plantillar una configuración con valores en tiempo de ejecución |
| `<< 'EOF'` o `<< "EOF"` | ❌ | Emitir scripts literales, JSON con `$`, expresiones regulares |
| `<<- EOF` | ✅ | Heredoc indentado dentro de una función — **solo tabuladores**, los espacios se preservan |
| `<<< "$var"` | ✅ (es una palabra normal) | Alimentar una cadena a un filtro sin `echo \|` |

Here-string vs. tubería con `echo` — la diferencia es una subshell, y sí importa:

```bash
$ echo "10 20 30" | read a b c ; echo "a=$a"
a=
$ read a b c <<< "10 20 30" ; echo "a=$a"
a=10
```

La tubería ejecuta `read` en una subshell cuyas variables se desvanecen. El here-string no hace fork.

**La sustitución de procesos** convierte un comando en un nombre de archivo. Es la herramienta para programas que se niegan a leer de stdin, o cuando necesitás *dos* flujos:

```bash
$ diff <(ssh web-01 'rpm -qa --qf "%{NAME}-%{VERSION}\n"' | sort) \
       <(ssh web-02 'rpm -qa --qf "%{NAME}-%{VERSION}\n"' | sort)
312a313
> nginx-1.26.2
$ echo <(true)
/dev/fd/63
```

El lado de salida, `>(...)`, es la forma de abanicar un flujo hacia varios destinos:

```bash
$ tar -cf - /srv/data \
    | tee >(sha256sum > /backup/data.sha256) \
          >(wc -c > /backup/data.size) \
    | zstd -19 -T0 -o /backup/data.tar.zst
```

> **Trampa:** el shell **no** espera a los hijos de `>(...)`. `/backup/data.sha256` puede seguir vacío en el instante en que la tubería retorna. O hacés `wait` sobre `$!` donde esté disponible, o reestructurás para que el consumidor sea la última etapa.

---

## 4. Tuberías: mecánica, contrapresión y estado de salida

### 4.1 Qué es realmente `|`

`cmd1 | cmd2` ejecuta `pipe2()` para obtener un extremo de lectura y uno de escritura, hace fork dos veces, hace `dup2` del extremo de escritura sobre el fd 1 del proceso izquierdo y del extremo de lectura sobre el fd 0 del proceso derecho, cierra los sobrantes en ambos, y ejecuta `execve`.

```bash
$ strace -f -e trace=pipe2,dup2,clone,execve -o /tmp/p.trace bash -c 'echo hi | cat' >/dev/null
$ grep -E 'pipe2|dup2' /tmp/p.trace
29310 pipe2([3, 4], 0)                  = 0
29311 dup2(4, 1)                        = 1
29312 dup2(3, 0)                        = 0
```

Propiedades clave que un SRE debe internalizar:

| Propiedad | Valor en Linux | Consecuencia operativa |
|---|---|---|
| Capacidad por defecto | 65536 bytes (16 páginas) | Un productor se bloquea cuando el consumidor queda 64 KiB atrás — esto *es* tu mecanismo de contrapresión |
| Capacidad máxima (sin privilegios) | `/proc/sys/fs/pipe-max-size`, por defecto 1048576 | `fcntl(F_SETPIPE_SZ)`; subirlo esconde la contrapresión, no la elimina |
| `PIPE_BUF` | 4096 bytes | Las escrituras **≤ 4096 bytes** a una tubería son atómicas; escritores concurrentes se intercalan limpiamente por debajo de ese tamaño, y se corrompen entre sí por encima |
| El lector cierra antes | El escritor recibe `SIGPIPE`, o `EPIPE` si la señal está bloqueada | Estado de salida **141** (`128 + 13`) |
| El escritor cierra | El `read()` del lector devuelve 0 (EOF) | Terminación normal del consumidor |
| Buffering | Búfer circular del kernel, nunca toca disco | Sin semántica `fsync`; un crash pierde los datos en vuelo |

La garantía de `PIPE_BUF` es la razón por la cual varios contenedores añadiendo líneas cortas a un FIFO compartido producen logs limpios, y por la cual un blob JSON de 200 KiB escrito por dos procesos al mismo FIFO sale hecho jirones.

La contrapresión es directamente observable:

```bash
$ yes | head -c 65536 > /dev/null ; echo "fits in the buffer"
fits in the buffer
$ ( yes 'x' & ) | (sleep 5; wc -l)   # producer blocks after ~64 KiB
```

```bash
$ cat /proc/$(pgrep -f 'yes x' | head -1)/wchan ; echo
pipe_write
```

Un proceso en `pipe_write` no está colgado — está regulado por un consumidor lento. Esa distinción ahorra un reinicio innecesario durante un incidente.

### 4.2 SIGPIPE — esperado, y frecuentemente malinterpretado como error

```bash
$ yes | head -n 3
y
y
y
$ echo "${PIPESTATUS[@]}"
141 0
```

`yes` no falló; le avisaron que el mundo dejó de escuchar. Pero con `set -o pipefail`, ese 141 se convierte en el estado de la tubería y un script con `set -e` termina:

```bash
$ bash -c 'set -euo pipefail; yes | head -n 3; echo "reached"'
y
y
y
$ echo $?
141
```

**Patrón de manejo:** tratá el 141 como éxito para productores que truncás deliberadamente.

```bash
head_safe() {
  local rc
  set +o pipefail
  "$@"
  rc=${PIPESTATUS[0]}
  set -o pipefail
  (( rc == 0 || rc == 141 ))
}
```

### 4.3 Estado de salida de una tubería — el contenido operativo de mayor valor de este objetivo

| Configuración del shell | `$?` después de `a \| b \| c` | Mejor para |
|---|---|---|
| Por defecto (POSIX) | Estado de salida de `c` solamente | Uso interactivo |
| `set -o pipefail` (bash/ksh/zsh, **no `sh` POSIX**) | El estado **distinto de cero** más a la derecha, si no 0 | Todo script no interactivo |
| `${PIPESTATUS[@]}` (bash) / `${pipestatus[@]}` (zsh) | Arreglo con todos los estados | Atribución precisa de errores y métricas |

```bash
$ false | true | true ; echo "default: $?"
default: 0
$ set -o pipefail
$ false | true | true ; echo "pipefail: $?"
pipefail: 1
$ grep -q nonexistent /etc/hostname | cat ; echo "statuses: ${PIPESTATUS[*]}"
statuses: 1 0
```

Plantilla de producción — esta es la solución al Incidente A:

```bash
#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'

declare -a rc
pg_dump --no-owner production | zstd -19 -T0 > "/backup/prod-$(date +%F).sql.zst"
rc=("${PIPESTATUS[@]}")

if (( rc[0] != 0 )); then
  echo "FATAL: pg_dump exited ${rc[0]}" >&2
  exit "${rc[0]}"
elif (( rc[1] != 0 )); then
  echo "FATAL: zstd exited ${rc[1]}" >&2
  exit "${rc[1]}"
fi
```

### 4.4 Subshells, `lastpipe` y variables perdidas

Cada componente de una tubería corre en una subshell. Los contadores incrementados dentro de la última etapa se evaporan:

```bash
$ count=0; printf 'a\nb\nc\n' | while read -r l; do ((count++)); done; echo "count=$count"
count=0
```

Tres soluciones correctas:

```bash
# 1. Redirect instead of pipe — no subshell for the loop
$ count=0; while read -r l; do ((count++)); done < <(printf 'a\nb\nc\n'); echo "count=$count"
count=3

# 2. Here-string
$ count=0; while read -r l; do ((count++)); done <<< $'a\nb\nc'; echo "count=$count"
count=3

# 3. lastpipe — requires job control OFF (i.e. non-interactive scripts)
$ bash -c 'shopt -s lastpipe; count=0; printf "a\nb\nc\n" | while read -r l; do ((count++)); done; echo "count=$count"'
count=3
```

### 4.5 Tuberías con nombre (FIFOs) — desacoplar procesos que no se pueden encadenar

Una tubería anónima requiere un ancestro común. Un FIFO es una entrada del sistema de archivos, así que procesos sin relación entre sí — distintos contenedores compartiendo un volumen, un demonio heredado y un enviador de logs moderno — pueden encontrarse.

```bash
$ mkfifo -m 0600 /var/run/app/applog.pipe
$ ls -l /var/run/app/applog.pipe
prw-------. 1 app app 0 Aug 26 15:02 /var/run/app/applog.pipe
```

```bash
$ ( logger -t legacy-app -f /var/run/app/applog.pipe & )
$ echo "checkout failed order=8812" > /var/run/app/applog.pipe
$ journalctl -t legacy-app -n 1 --no-pager
Aug 26 15:03:11 node-01 legacy-app[31220]: checkout failed order=8812
```

| Propiedad | Tubería anónima `\|` | Tubería con nombre (FIFO) |
|---|---|---|
| Espacio de nombres | Solo el kernel, heredada vía fork | Ruta del sistema de archivos |
| Procesos sin relación | ❌ | ✅ |
| `open()` para escritura se bloquea | n/a | ✅ hasta que un lector abra (salvo `O_NONBLOCK`) |
| Sobrevive a reinicios | ❌ | El *nodo* sobrevive; los datos en búfer no |
| Múltiples escritores | Raro | Común — atómico por debajo de `PIPE_BUF` |
| Uso de disco | 0 | 0 (los datos nunca llegan al almacenamiento de respaldo) |
| Riesgo principal en producción | — | Un escritor se bloquea para siempre si el lector muere |

> **Advertencia operativa:** si el único lector de un FIFO termina, el siguiente escritor recibe `SIGPIPE`; si *ningún* lector lo abre jamás, un escritor bloqueante se cuelga en `open()` indefinidamente. Los sidecars de envío de logs construidos sobre FIFOs necesitan un lector supervisado de forma independiente del escritor.

---

## 5. `tee` — Dividir un flujo sin perderlo

`tee` lee de stdin, lo escribe en stdout **y** en cada archivo pasado como argumento. Es la respuesta canónica a "enviar la salida tanto a la pantalla como a un archivo", que es un subobjetivo explícito de 103.4.

```bash
$ journalctl -u kubelet -n 5 --no-pager | tee /tmp/kubelet.snippet | wc -l
5
$ head -2 /tmp/kubelet.snippet
Aug 26 15:10:02 node-01 kubelet[1188]: I0826 15:10:02.114 kubelet.go:2437] "SyncLoop (PLEG)"
Aug 26 15:10:04 node-01 kubelet[1188]: I0826 15:10:04.902 kubelet.go:2451] "SyncLoop (probe)"
```

| Bandera | Efecto | Relevancia en producción |
|---|---|---|
| `-a`, `--append` | `O_APPEND` en lugar de truncar | Obligatoria para captura de logs de larga duración |
| `-i`, `--ignore-interrupts` | Ignora `SIGINT` | Conserva la transcripción cuando el operador presiona Ctrl-C |
| `-p` | Diagnostica errores de escritura, no termina ante `SIGPIPE` | Tuberías con múltiples destinos donde uno puede desaparecer |
| `--output-error=warn\|exit\|warn-nopipe` | Política ante fallo de escritura | `exit` para backups donde perder un destino en silencio es inaceptable |

### 5.1 Los tres modismos canónicos de `tee`

```bash
# 1. Capture everything (stdout AND stderr) while still watching it live
$ ./deploy.sh 2>&1 | tee -a /var/log/deploy-$(date +%F).log

# 2. Write to a root-owned path from an unprivileged shell.
#    `sudo cmd > /etc/x` fails: the *shell* opens the file, and the shell is not root.
$ echo 'vm.swappiness = 1' | sudo tee /etc/sysctl.d/99-swappiness.conf
vm.swappiness = 1
$ echo 'net.ipv4.ip_forward = 1' | sudo tee -a /etc/sysctl.d/99-swappiness.conf > /dev/null

# 3. Fan out to N heterogeneous sinks
$ kubectl get events -A -w \
    | tee >(grep -E 'Failed|OOMKilled' >> /var/log/k8s-bad-events.log) \
          >(logger -t k8s-events) \
    > /dev/null
```

### 5.2 La trampa del estado de salida que introduce `tee`

```bash
$ false | tee /tmp/x.log ; echo "status: $?"
status: 0
$ set -o pipefail
$ false | tee /tmp/x.log ; echo "status: $?"
status: 1
```

Cualquier `| tee` insertado "solo para ver la salida" convierte un comando que falla en uno que pasa, salvo que `pipefail` esté activo o se inspeccione `PIPESTATUS`. Esta es la razón por la que los envoltorios de CI que agregan `| tee build.log` empiezan a reportar builds en verde que no producen artefactos.

### 5.3 `tee` frente a las alternativas

| Requisito | Herramienta | Compromiso |
|---|---|---|
| Pantalla + un archivo | `tee file` | Lo más simple; pierde el estado de salida sin `pipefail` |
| Pantalla + archivo, conservando el estado de salida | `cmd \|& tee f; exit ${PIPESTATUS[0]}` | Correcto, más verboso |
| Transcripción de *sesión* completa incl. códigos de control de la TTY | `script -q -c 'cmd' /tmp/t.log` | Asigna un **pty** — también anula el buffering por bloques (§7) |
| Solo archivo, sin pantalla | `cmd > file 2>&1` | Un fd, sin proceso extra |
| Sobrescribir un archivo de entrada | `sponge` (moreutils) | Almacena en RAM; no es atómico |
| Duplicar hacia un *proceso* | `tee >(proc)` | Solo bash; el shell no espera al hijo |
| Duplicar para todo el script | `exec > >(tee -a f) 2>&1` | Elegante; el hijo sobrevive a la redirección salvo que se maneje |

---

## 6. `xargs` — Convertir salida en argumentos

Una tubería conecta **stdout con stdin**. Muchas herramientas esenciales (`rm`, `chown`, `kubectl delete`, `systemctl`) toman **argumentos**, no stdin. `xargs` es el puente, y usar la salida de un comando como argumentos de otro es un subobjetivo nombrado de 103.4.

### 6.1 El límite que hace necesario a `xargs`

```bash
$ getconf ARG_MAX
2097152
$ rm /var/log/spool/*.tmp
-bash: /usr/bin/rm: Argument list too long
```

`E2BIG` proviene de `execve(2)`. Se aplican dos techos distintos: el tamaño total de argv+envp (`ARG_MAX`, típicamente 2 MiB o 1/4 del límite de pila) y `MAX_ARG_STRLEN` = 131072 bytes para cualquier argumento **individual**. `xargs` lee el límite y arma lotes en consecuencia:

```bash
$ xargs --show-limits < /dev/null
Your environment variables take up 3186 bytes
POSIX upper limit on argument length (this system): 2091118
POSIX smallest allowable upper limit on argument length (all systems): 4096
Maximum length of command we could actually use: 2087932
Size of command buffer we are actually using: 131072
Maximum parallelism (--max-procs must be no greater than): 2147483647
```

### 6.2 Banderas que importan en producción

| Bandera | Significado | Cuándo es obligatoria |
|---|---|---|
| `-0`, `--null` | Los ítems de entrada están separados por NUL | **Siempre**, con `find -print0` — el único separador imposible en un nombre de archivo |
| `-d DELIM` | Delimitador personalizado | Entrada solo con saltos de línea: `-d '\n'` |
| `-r`, `--no-run-if-empty` | No ejecutar una vez con entrada vacía | Solo GNU, pero crítica: `xargs rm -rf` con entrada vacía ejecuta `rm -rf` sin argumentos |
| `-n N` | Como máximo N argumentos por invocación | Limitar la tasa de una CLI respaldada por una API |
| `-L N` | Como máximo N **líneas** por invocación | Entrada orientada a líneas |
| `-I {}` | Reemplaza `{}` en cualquier parte del comando | Implica `-L 1` — **un proceso por ítem**, mucho más lento |
| `-P N` | Ejecuta N invocaciones en paralelo | `-P 0` = tantas como sea posible; combinar con `-n` |
| `-t` | Imprime cada comando en stderr antes de ejecutarlo | Auditoría |
| `-p` | Pide confirmación | Operaciones destructivas interactivas |
| `-a FILE` | Lee los ítems de FILE en lugar de stdin | Libera stdin para el comando hijo |
| `-s N` | Longitud máxima del comando en bytes | Sortear el `ARG_MAX` remoto sobre `ssh` |

### 6.3 Formas correctas e incorrectas, lado a lado

```bash
$ mkdir -p /tmp/lab && cd /tmp/lab && touch 'report final.log' 'ok.log'
$ find . -name '*.log' | xargs rm -v
removed './ok.log'
rm: cannot remove './report': No such file or directory
rm: cannot remove 'final.log': No such file or directory
```

```bash
$ touch 'report final.log' 'ok.log'
$ find . -name '*.log' -print0 | xargs -0 -r rm -v
removed './report final.log'
removed './ok.log'
```

Entrada vacía, con y sin `-r`:

```bash
$ find /tmp/lab -name '*.nomatch' | xargs -t ls
ls
ls: cannot access ...   # ran once with no arguments — lists the CWD
$ find /tmp/lab -name '*.nomatch' | xargs -r -t ls
$ echo $?
0
```

Colocación con `-I`, y la diferencia en el armado de lotes:

```bash
$ printf 'alpha\nbravo\ncharlie\n' | xargs -t echo PREFIX
echo PREFIX alpha bravo charlie
PREFIX alpha bravo charlie

$ printf 'alpha\nbravo\ncharlie\n' | xargs -t -I{} echo PREFIX {} SUFFIX
echo PREFIX alpha SUFFIX
PREFIX alpha SUFFIX
echo PREFIX bravo SUFFIX
PREFIX bravo SUFFIX
echo PREFIX charlie SUFFIX
PREFIX charlie SUFFIX
```

Paralelismo con concurrencia acotada — el patrón para drenar nodos o precalentar cachés sin fundir el plano de control:

```bash
$ kubectl get pods -n prod -o name \
    | xargs -r -n1 -P4 -I{} sh -c 'kubectl logs -n prod {} --tail=1 >/dev/null 2>&1 || echo "no logs: {}"'
no logs: pod/batch-runner-7f9c4d8b6-x2llq
```

> Con `-P > 1`, los hijos comparten el fd 1. Las líneas de salida más largas que `PIPE_BUF` (4096) pueden intercalarse. O mantenés las líneas cortas, o hacés que cada hijo escriba en su propio archivo y después los concatenás.

### 6.4 `xargs` frente a `find -exec`, a un bucle del shell y a `parallel`

| Enfoque | Procesos lanzados | Maneja nombres raros | Paralelo | Portable | Notas |
|---|---|---|:---:|:---:|---|
| `find … -exec cmd {} \;` | uno por archivo | ✅ (no hay shell involucrado) | ❌ | POSIX | El más lento; correcto por construcción |
| `find … -exec cmd {} +` | por lotes (como `xargs`) | ✅ | ❌ | POSIX | **La mejor opción por defecto** cuando `find` ya es la fuente |
| `find … -print0 \| xargs -0 -r cmd` | por lotes | ✅ | ✅ vía `-P` | GNU/BSD | Necesario cuando querés paralelismo o una fuente que no sea `find` |
| `while IFS= read -r -d '' f; do …; done < <(find … -print0)` | 0 extra (builtins) | ✅ | ❌ | bash | Lógica de shell completa por ítem; sin costo de `execve` para builtins |
| `parallel` (GNU) | por lotes/paralelo | ✅ | ✅ | paquete extra | Control de trabajos, reintentos, ejecución remota; no entra en el examen |

```bash
$ find /var/log -name '*.log' -type f -exec stat -c '%s %n' {} + | sort -rn | head -3
2147483 /var/log/journal/9f0.../system.journal
 894112 /var/log/audit/audit.log
 331290 /var/log/messages
```

---

## 7. Buffering: por qué una redirección correcta igual no produce salida

El shell cablea los descriptores correctamente, y sin embargo el log está vacío. La causa está en libc, no en el kernel.

| El fd 1 es un… | Modo stdio de glibc | Disparador del vaciado |
|---|---|---|
| TTY | búfer por líneas | cada `\n` |
| tubería, archivo, socket | **búfer completo**, `BUFSIZ`/st_blksize (4096+) | búfer lleno, `fflush()`, o `exit()` limpio |
| fd 2 (cualquier destino) | sin búfer | cada escritura |

Consecuencias: un proceso terminado con `SIGKILL` pierde por completo su stdout en búfer; un proceso que simplemente es lento parece silencioso durante minutos.

### 7.1 Reproducirlo y arreglarlo

```bash
$ python3 -c 'import time,sys
for i in range(3):
    print(f"tick {i}"); time.sleep(1)' | cat
# ...3 seconds of nothing, then:
tick 0
tick 1
tick 2
```

| Solución | Comando | Se aplica a |
|---|---|---|
| Bandera de la aplicación | `python3 -u`, `PYTHONUNBUFFERED=1`, `node` (ya usa búfer por líneas hacia tuberías desde v6), Go ajeno a `stdbuf` (ya sin búfer) | Lo mejor cuando está disponible |
| Bandera propia de la herramienta | `grep --line-buffered`, `sed -u`, `awk` + `fflush()`, `jq --unbuffered`, `tcpdump -l`, `stdbuf` | Filtros *dentro* de la tubería |
| `stdbuf` (coreutils) | `stdbuf -oL -eL cmd` | Programas enlazados dinámicamente que usan el stdio de glibc; **sin efecto** sobre binarios estáticos, binarios setuid, o programas que llaman a `setvbuf()` por su cuenta |
| Simular una TTY | `script -qec 'cmd' /dev/null` o `unbuffer cmd` (expect) | Cualquier cosa, incluidos binarios estáticos |

```bash
$ stdbuf -oL python3 -c 'import time
for i in range(3):
    print(f"tick {i}"); time.sleep(1)' | cat
tick 0
tick 1
tick 2
```

> **Nota:** `stdbuf -oL python3` funciona solamente porque CPython consulta su propia lógica; para un programa que fija `setvbuf(stdout, buf, _IOFBF, N)` en el código, solo ayuda un pty. Verificalo con `ltrace -e setvbuf` o leyendo el código fuente.

La víctima clásica de varias etapas:

```bash
# Broken: grep fully buffers because its stdout is a pipe
$ tail -F /var/log/app.log | grep ERROR | ts

# Fixed
$ tail -F /var/log/app.log | grep --line-buffered ERROR | ts
```

---

## 8. Infraestructura completa de producción

Todo lo que sigue está completo y es sintácticamente válido — sin omisiones.

### 8.1 Imagen de contenedor: forzar una aplicación no canalizable hacia stdout

El patrón que usa la imagen oficial de `nginx`: reemplazar los archivos de log con enlaces simbólicos al stdout/stderr del propio contenedor.

```dockerfile
# syntax=docker/dockerfile:1.7
FROM debian:12-slim

RUN set -eux; \
    apt-get update; \
    apt-get install -y --no-install-recommends nginx ca-certificates; \
    rm -rf /var/lib/apt/lists/*; \
    # The application insists on writing to files. Point those files at the
    # container's stdout/stderr so the runtime's log driver collects them.
    ln -sf /dev/stdout /var/log/nginx/access.log; \
    ln -sf /dev/stderr /var/log/nginx/error.log

# PID 1 must NOT daemonize: the runtime attaches the pipes to PID 1's fds.
STOPSIGNAL SIGQUIT
EXPOSE 8080
CMD ["nginx", "-g", "daemon off;"]
```

Verificación dentro de un contenedor en ejecución:

```bash
$ docker run -d --name web -p 8080:80 platform/nginx:1.26
b91f2c0a7de4
$ docker exec web ls -l /proc/1/fd/1 /proc/1/fd/2
l-wx------ 1 root root 64 Aug 26 16:02 /proc/1/fd/1 -> pipe:[184229]
l-wx------ 1 root root 64 Aug 26 16:02 /proc/1/fd/2 -> pipe:[184230]
$ docker exec web readlink /var/log/nginx/access.log
/dev/stdout
$ curl -s localhost:8080 >/dev/null && docker logs --tail 1 web
172.17.0.1 - - [26/Aug/2026:16:02:41 +0000] "GET / HTTP/1.1" 200 615 "-" "curl/8.6.0" "-"
```

### 8.2 Kubernetes: los dos flujos, y cómo los ve el kubelet

```yaml
---
apiVersion: v1
kind: Namespace
metadata:
  name: streams-lab
---
apiVersion: v1
kind: ConfigMap
metadata:
  name: stream-emitter
  namespace: streams-lab
data:
  emit.sh: |
    #!/bin/sh
    set -eu
    # Two independent streams, distinguishable by the CRI log format.
    i=0
    while [ "$i" -lt 20 ]; do
      printf '%s stdout-line seq=%d\n' "$(date -Iseconds)" "$i"
      printf '%s stderr-line seq=%d\n' "$(date -Iseconds)" "$i" >&2
      i=$((i + 1))
      sleep 2
    done
    # Kubernetes reads this file to populate the container's termination message.
    printf 'emitter finished cleanly after %d iterations\n' "$i" > /dev/termination-log
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: stream-demo
  namespace: streams-lab
  labels:
    app.kubernetes.io/name: stream-demo
spec:
  replicas: 1
  selector:
    matchLabels:
      app.kubernetes.io/name: stream-demo
  template:
    metadata:
      labels:
        app.kubernetes.io/name: stream-demo
    spec:
      securityContext:
        runAsNonRoot: true
        runAsUser: 65534
        runAsGroup: 65534
        fsGroup: 65534
        seccompProfile:
          type: RuntimeDefault
      containers:
        - name: emitter
          image: busybox:1.36
          command: ["/bin/sh", "/scripts/emit.sh"]
          terminationMessagePath: /dev/termination-log
          terminationMessagePolicy: FallbackToLogsOnError
          env:
            # Belt and braces for interpreted runtimes; harmless for sh.
            - name: PYTHONUNBUFFERED
              value: "1"
          resources:
            requests:
              cpu: 10m
              memory: 16Mi
            limits:
              cpu: 100m
              memory: 64Mi
          securityContext:
            allowPrivilegeEscalation: false
            readOnlyRootFilesystem: true
            capabilities:
              drop: ["ALL"]
          volumeMounts:
            - name: scripts
              mountPath: /scripts
              readOnly: true
            - name: tmp
              mountPath: /tmp
      volumes:
        - name: scripts
          configMap:
            name: stream-emitter
            defaultMode: 0555
        - name: tmp
          emptyDir:
            medium: Memory
            sizeLimit: 8Mi
```

```bash
$ kubectl apply -f stream-demo.yaml
namespace/streams-lab created
configmap/stream-emitter created
deployment.apps/stream-demo created

$ kubectl -n streams-lab logs deploy/stream-demo --tail=4
2026-08-26T16:20:10+00:00 stdout-line seq=3
2026-08-26T16:20:10+00:00 stderr-line seq=3
2026-08-26T16:20:12+00:00 stdout-line seq=4
2026-08-26T16:20:12+00:00 stderr-line seq=4
```

`kubectl logs` fusiona ambos flujos. Para separarlos hay que leer el log CRI en el nodo — esta es la capa que la abstracción esconde:

```bash
$ POD_UID=$(kubectl -n streams-lab get pod -l app.kubernetes.io/name=stream-demo \
    -o jsonpath='{.items[0].metadata.uid}')
$ sudo tail -4 /var/log/pods/streams-lab_stream-demo-*_${POD_UID}/emitter/0.log
2026-08-26T16:20:12.114882301Z stdout F 2026-08-26T16:20:12+00:00 stdout-line seq=4
2026-08-26T16:20:12.115901744Z stderr F 2026-08-26T16:20:12+00:00 stderr-line seq=4
2026-08-26T16:20:14.117003912Z stdout F 2026-08-26T16:20:14+00:00 stdout-line seq=5
2026-08-26T16:20:14.117994120Z stderr F 2026-08-26T16:20:14+00:00 stderr-line seq=5
```

Campos: marca temporal RFC3339Nano, **nombre del flujo** (`stdout`/`stderr`), etiqueta (`F` = línea completa, `P` = parcial), mensaje. containerd divide cualquier línea de más de **16 KiB** en fragmentos `P`; una línea de log JSON por encima de ese límite llega a tu agregador como varias piezas imposibles de parsear, salvo que el enviador reensamble `P`/`F`.

```bash
$ sudo awk '$2=="stderr"' /var/log/pods/streams-lab_*/emitter/0.log | wc -l
20
```

### 8.3 Kubernetes: sidecar consumiendo un FIFO de una aplicación heredada

Para una aplicación que no puede escribir a stdout, una tubería con nombre sobre un `emptyDir` compartido convierte la salida a archivo en un flujo, con **cero uso de disco** y sin rotación.

```yaml
---
apiVersion: v1
kind: ConfigMap
metadata:
  name: fifo-bridge
  namespace: streams-lab
data:
  setup-fifo.sh: |
    #!/bin/sh
    set -eu
    # Must exist before either the app or the shipper opens it.
    [ -p /shared/app.pipe ] || mkfifo -m 0660 /shared/app.pipe
    echo "fifo ready: $(ls -l /shared/app.pipe)"
  legacy-app.sh: |
    #!/bin/sh
    set -eu
    # The "legacy" application: it only knows how to append to a log file.
    LOGFILE=/shared/app.pipe
    i=0
    while :; do
      printf '{"ts":"%s","level":"info","seq":%d,"msg":"transaction processed"}\n' \
        "$(date -Iseconds)" "$i" >> "$LOGFILE"
      i=$((i + 1))
      sleep 3
    done
  shipper.sh: |
    #!/bin/sh
    set -eu
    # Reader side. Reopen on EOF: every time the last writer closes the FIFO,
    # read() returns 0 and `cat` exits. A supervised loop keeps the reader alive.
    while :; do
      cat /shared/app.pipe || true
      sleep 0.2
    done
---
apiVersion: v1
kind: Pod
metadata:
  name: fifo-sidecar
  namespace: streams-lab
spec:
  restartPolicy: Never
  initContainers:
    - name: create-fifo
      image: busybox:1.36
      command: ["/bin/sh", "/scripts/setup-fifo.sh"]
      volumeMounts:
        - name: scripts
          mountPath: /scripts
          readOnly: true
        - name: shared
          mountPath: /shared
    # Native sidecar (Kubernetes 1.29+): an initContainer with restartPolicy:
    # Always starts before the app containers and keeps running. This guarantees
    # a reader is attached to the FIFO before the writer opens it.
    - name: log-shipper
      image: busybox:1.36
      restartPolicy: Always
      command: ["/bin/sh", "/scripts/shipper.sh"]
      resources:
        requests: { cpu: 5m, memory: 8Mi }
        limits:   { cpu: 50m, memory: 32Mi }
      volumeMounts:
        - name: scripts
          mountPath: /scripts
          readOnly: true
        - name: shared
          mountPath: /shared
  containers:
    - name: legacy-app
      image: busybox:1.36
      command: ["/bin/sh", "/scripts/legacy-app.sh"]
      resources:
        requests: { cpu: 10m, memory: 16Mi }
        limits:   { cpu: 100m, memory: 64Mi }
      volumeMounts:
        - name: scripts
          mountPath: /scripts
          readOnly: true
        - name: shared
          mountPath: /shared
  volumes:
    - name: scripts
      configMap:
        name: fifo-bridge
        defaultMode: 0555
    - name: shared
      emptyDir:
        medium: Memory
        sizeLimit: 1Mi
```

```bash
$ kubectl apply -f fifo-sidecar.yaml
configmap/fifo-bridge created
pod/fifo-sidecar created

$ kubectl -n streams-lab logs fifo-sidecar -c log-shipper --tail=2
{"ts":"2026-08-26T16:41:07+00:00","level":"info","seq":11,"msg":"transaction processed"}
{"ts":"2026-08-26T16:41:10+00:00","level":"info","seq":12,"msg":"transaction processed"}

$ kubectl -n streams-lab exec fifo-sidecar -c legacy-app -- sh -c 'ls -l /shared; du -sh /shared'
prw-rw----    1 root     root             0 Aug 26 16:40 app.pipe
0	/shared
```

El `emptyDir` nunca crece: el FIFO retiene como mucho 64 KiB en memoria del kernel, y los datos se consumen tan rápido como se producen.

### 8.4 systemd: redirección en la capa del gestor de servicios

```ini
# /etc/systemd/system/order-processor.service
[Unit]
Description=Order Processor (stream-correct logging)
Documentation=https://internal.example.com/runbooks/order-processor
After=network-online.target
Wants=network-online.target

[Service]
Type=exec
User=order
Group=order
WorkingDirectory=/opt/order-processor

# The unit's fd 1 and fd 2 become AF_UNIX sockets to systemd-journald.
# Do NOT add a shell redirection in ExecStart; it would bypass this entirely.
StandardInput=null
StandardOutput=journal
StandardError=journal
SyslogIdentifier=order-processor

# Defeat glibc full buffering: fd 1 is a socket, not a TTY.
Environment=PYTHONUNBUFFERED=1
Environment=LC_ALL=C.UTF-8

ExecStart=/opt/order-processor/venv/bin/python -u -m order_processor.main

Restart=on-failure
RestartSec=5s
TimeoutStopSec=30s
KillSignal=SIGTERM
# Give the process a chance to flush before SIGKILL.
FinalKillSignal=SIGKILL

# Hardening — unrelated to streams, but these units ship together in production.
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=strict
ProtectHome=true
ReadWritePaths=/var/lib/order-processor
CapabilityBoundingSet=
LimitNOFILE=65536

[Install]
WantedBy=multi-user.target
```

```bash
$ sudo systemctl daemon-reload && sudo systemctl restart order-processor
$ systemctl show order-processor -p StandardOutput -p StandardError -p MainPID
StandardOutput=journal
StandardError=journal
MainPID=41902
$ sudo ls -l /proc/41902/fd/{0,1,2}
lr-x------. 1 order order 64 Aug 26 17:01 /proc/41902/fd/0 -> /dev/null
l-wx------. 1 order order 64 Aug 26 17:01 /proc/41902/fd/1 -> socket:[512338]
l-wx------. 1 order order 64 Aug 26 17:01 /proc/41902/fd/2 -> socket:[512338]
$ journalctl -u order-processor -n 2 --no-pager -o short-iso
2026-08-26T17:01:12+0000 node-01 order-processor[41902]: ready, listening on :9090
2026-08-26T17:01:14+0000 node-01 order-processor[41902]: processed order=44120 in 18ms
```

Para separar los dos flujos a nivel del journal, `StandardError=` acepta distintos destinos:

```ini
StandardOutput=journal
StandardError=append:/var/log/order-processor/errors.log
```

| Valor de `StandardOutput=` | Adónde apunta el fd 1 | Responsabilidad de la rotación |
|---|---|---|
| `journal` (por defecto) | Socket `AF_UNIX` hacia journald | journald (`SystemMaxUse=`) |
| `inherit` | Lo que sea que tenga el propio systemd | — |
| `null` | `/dev/null` | ninguna |
| `tty` | El `TTYPath=` configurado | ninguna |
| `file:/path` | `open(O_CREAT\|O_TRUNC)` en cada arranque | **vos** (`logrotate`) |
| `append:/path` | `open(O_CREAT\|O_APPEND)` | **vos** |
| `truncate:/path` | Trunca en cada arranque | **vos** |
| `socket` | fd heredado por activación por socket | — |
| `kmsg` | Búfer circular del kernel | el búfer |

### 8.5 `logrotate`: las dos estrategias, y por qué una pierde datos

Si *tenés* que conservar logs basados en archivos, entendé la consecuencia a nivel de fd. Renombrar un archivo no cambia la descripción de archivo abierto del escritor — el proceso sigue escribiendo en el inodo renombrado, y el archivo nuevo queda en 0 bytes para siempre.

```conf
# /etc/logrotate.d/order-processor
/var/log/order-processor/*.log {
    daily
    rotate 14
    missingok
    notifempty
    compress
    delaycompress
    dateext
    dateformat -%Y-%m-%d
    create 0640 order order
    sharedscripts
    postrotate
        # CORRECT: tell the process to close and reopen its log files.
        # Zero data loss; the old inode is released the instant it reopens.
        /bin/systemctl kill -s SIGUSR1 order-processor.service 2>/dev/null || true
    endscript
}

# Only for a process that cannot be signalled to reopen.
/var/log/legacy-vendor/*.log {
    size 100M
    rotate 5
    compress
    missingok
    # copytruncate: copy the file, then truncate the ORIGINAL inode in place.
    # The writer's fd and offset are untouched, so it keeps working — but any
    # bytes written between the copy and the truncate are LOST, and the
    # truncated file becomes sparse until the offset catches up.
    copytruncate
}
```

| Estrategia | Ventana de pérdida de datos | Requiere cooperación de la app | Deja archivos dispersos | Veredicto |
|---|---|:---:|:---:|---|
| `create` + señal de reapertura | ninguna | ✅ (manejador de SIGHUP/SIGUSR1) | ❌ | **Preferida** |
| `copytruncate` | carrera copia→truncado | ❌ | ✅ | Último recurso para binarios de proveedores |
| Sin rotación, log a stdout | ninguna | ✅ | ❌ | **Correcta para contenedores** |

---

## 9. Verificación y diagnóstico de fallas

### 9.1 Síntoma → causa → comando

| Síntoma | Causa más probable | Primer comando a ejecutar |
|---|---|---|
| `docker logs` / `kubectl logs` vacío, proceso sano | La app escribe a un archivo, o se demonizó lejos de los fds del PID 1 | `readlink /proc/1/fd/1` dentro del contenedor |
| La salida aparece en ráfagas de ~4 KiB o solo al terminar | Búfer completo de glibc sobre un fd 1 que no es TTY | `stdbuf -oL cmd` / `script -qec` para confirmar |
| La tubería reporta éxito pero no produjo nada | El estado de salida de la última etapa enmascara la falla | `echo "${PIPESTATUS[@]}"`; agregar `set -o pipefail` |
| `df` lleno, `du` pequeño | Archivo eliminado todavía abierto | `lsof +L1 /var` |
| Código de salida 141 | `SIGPIPE` — el lector cerró primero | Esperado con `head`; si no, verificá la muerte prematura del consumidor |
| `Argument list too long` | `E2BIG` de `execve` | `getconf ARG_MAX`; cambiar a `find -exec … +` o `xargs` |
| El comando consumió los archivos equivocados | División por palabras ante espacios en los nombres de archivo | Reejecutar con `-print0` / `xargs -0` |
| Un `xargs` destructivo corrió con entrada vacía | Falta `-r` | Agregar `--no-run-if-empty` |
| Escritor trabado, consumidor lento | Búfer de la tubería lleno (contrapresión, no un cuelgue) | `cat /proc/PID/wchan` → `pipe_write` |
| `sudo cmd > /root/file` → Permission denied | El *shell* abre el archivo, sin privilegios | `cmd \| sudo tee /root/file` |
| El archivo de log rotó pero queda en 0 bytes | El escritor retiene el inodo viejo | `lsof -p PID \| grep '(deleted)'`, señalar reapertura |
| Una variable asignada en un bucle queda vacía después | El bucle corrió en la subshell de la tubería | Usar `< <(...)`, `<<<`, o `shopt -s lastpipe` |

### 9.2 Diagnosticar "el disco está lleno pero no hay nada"

```bash
$ df -h /var
Filesystem            Size  Used Avail Use% Mounted on
/dev/mapper/vg0-var   200G  200G     0 100% /var
$ du -sh /var
3.1G	/var

$ sudo lsof +L1 /var
COMMAND     PID  USER   FD   TYPE DEVICE     SIZE/OFF NLINK     NODE NAME
java      21877   app    3w   REG  253,4 189223448576     0 20971621 /var/log/app/app.log (deleted)

$ sudo ls -l /proc/21877/fd/3
l-wx------. 1 app app 64 Aug 26 17:22 /proc/21877/fd/3 -> '/var/log/app/app.log (deleted)'
```

Recuperá el contenido antes de liberar el espacio, si los datos importan:

```bash
$ sudo cp /proc/21877/fd/3 /mnt/rescue/app.log.recovered
$ ls -lh /mnt/rescue/app.log.recovered
-rw-r--r--. 1 root root 176G Aug 26 17:25 /mnt/rescue/app.log.recovered
```

Liberá el espacio sin reiniciar el servicio — truncá **a través** del descriptor:

```bash
$ sudo truncate -s 0 /proc/21877/fd/3
$ df -h /var
Filesystem            Size  Used Avail Use% Mounted on
/dev/mapper/vg0-var   200G  3.2G  188G   2% /var
```

> El offset del escritor *no* se reinicia con `truncate`, así que el archivo queda disperso y `ls -l` va a seguir mostrando un tamaño aparente grande. `du` muestra la asignación real. Este es un compromiso controlado: una recuperación de espacio en pleno incidente, no un sustituto de arreglar la rotación.

### 9.3 Probar adónde va realmente un flujo

```bash
$ sudo strace -f -y -e trace=write,openat,dup2,pipe2 -p 21877 2>&1 | head -6
strace: Process 21877 attached
write(3</var/log/app/app.log (deleted)>, "2026-08-26 17:31:02 INFO order 4"..., 61) = 61
write(1<pipe:[512901]>, "heartbeat ok\n", 13) = 13
```

La bandera `-y` imprime la ruta resuelta de cada descriptor — esa única bandera responde "qué fd va adónde" más rápido que cualquier cantidad de lectura de configuración.

### 9.4 Verificar la hipótesis de buffering en 20 segundos

```bash
$ ./ingest --verbose | head -1     # nothing for 30s -> suspicious
^C
$ ./ingest --verbose > /dev/tty | head -1   # bypass the pipe: output is immediate?
processing batch 1
```

Si la salida es inmediata hacia una TTY y demorada hacia una tubería, es buffering, no un cuelgue. Confirmá y arreglá:

```bash
$ stdbuf -oL -eL ./ingest --verbose | head -1
processing batch 1
```

### 9.5 Una lista de verificación para cualquier ruta de logs que tengas a cargo

```bash
# 1. Does the process actually hold the descriptors you think it does?
$ sudo ls -l /proc/$(pgrep -f order_processor)/fd/{0,1,2}

# 2. Are both streams reaching the collector?
$ journalctl -u order-processor -n 20 -o json | jq -r '.PRIORITY + " " + .MESSAGE' | sort -u | head

# 3. Is anything buffered rather than delivered?
$ sudo cat /proc/$(pgrep -f order_processor)/wchan; echo

# 4. Does the pipeline propagate failure?
$ bash -c 'set -o pipefail; false | tee /dev/null; echo $?'
1

# 5. Is any log file being written while unlinked?
$ sudo lsof +L1 / 2>/dev/null | awk 'NR==1 || $NF ~ /deleted/'

# 6. Will a rotation actually work?
$ sudo logrotate -d /etc/logrotate.d/order-processor
```

### 9.6 Laboratorio guiado — verificá cada afirmación de este tema

```bash
# --- Descriptors -----------------------------------------------------------
$ mkdir -p ~/streams-lab && cd ~/streams-lab
$ ls /etc/hostname /etc/nope > out.txt 2> err.txt
$ cat out.txt; echo '---'; cat err.txt
/etc/hostname
---
ls: cannot access '/etc/nope': No such file or directory

# --- Ordering --------------------------------------------------------------
$ ls /etc/hostname /etc/nope > both.txt 2>&1 ; wc -l both.txt
2 both.txt
$ ls /etc/hostname /etc/nope 2>&1 > only-out.txt ; wc -l only-out.txt
ls: cannot access '/etc/nope': No such file or directory
1 only-out.txt

# --- Same file, two descriptions (data corruption) --------------------------
$ ls /etc/hostname /etc/nope > bad.txt 2> bad.txt ; cat -A bad.txt | head -2
/etc/hostname$
ls: cannot access '/etc/nope': No such file or directory$

# --- Pipe capacity and back-pressure ---------------------------------------
$ (dd if=/dev/zero bs=1024 count=100 2>/dev/null | (sleep 2; wc -c)) &
$ sleep 0.5; cat /proc/$(pgrep -n dd)/wchan; echo
pipe_write

# --- PIPESTATUS ------------------------------------------------------------
$ grep -q root /etc/passwd | grep -q nosuchuser | true; echo "${PIPESTATUS[*]}"
0 1 0

# --- tee to a privileged path ----------------------------------------------
$ echo 'kernel.pid_max = 4194304' | sudo tee /etc/sysctl.d/98-pidmax.conf
kernel.pid_max = 4194304

# --- xargs safety ----------------------------------------------------------
$ touch 'a b.tmp' 'c.tmp'
$ find . -name '*.tmp' -print0 | xargs -0 -r -t rm -v
rm -v ./a b.tmp ./c.tmp
removed './a b.tmp'
removed './c.tmp'

# --- Process substitution ---------------------------------------------------
$ diff <(printf 'a\nb\nc\n') <(printf 'a\nx\nc\n')
2c2
< b
---
> x

# --- Named pipe -------------------------------------------------------------
$ mkfifo demo.pipe
$ (wc -l < demo.pipe &) ; printf 'l1\nl2\nl3\n' > demo.pipe
3
$ rm -f demo.pipe
```

---

## 10. Consolidación enfocada en el examen

| Tenés que poder… | Respuesta canónica |
|---|---|
| Enviar stdout a un archivo, descartar stderr | `cmd > out.txt 2> /dev/null` |
| Enviar stderr a un archivo, dejar stdout en pantalla | `cmd 2> err.txt` |
| Fusionar ambos en un archivo | `cmd > all.txt 2>&1` **o** `cmd &> all.txt` (bash) |
| Añadir ambos | `cmd >> all.txt 2>&1` **o** `cmd &>> all.txt` |
| Descartar todo | `cmd > /dev/null 2>&1` |
| Enviar stdout a un archivo *y* a la pantalla | `cmd \| tee out.txt` |
| Añadir mientras se muestra | `cmd \| tee -a out.txt` |
| Ambos flujos a pantalla y archivo | `cmd 2>&1 \| tee -a out.txt` |
| Imprimir a stderr desde un script | `echo "message" >&2` |
| Alimentar un archivo a la stdin de un comando | `cmd < in.txt` |
| Alimentar un bloque literal a stdin | `cmd <<'EOF' … EOF` |
| Alimentar una sola cadena a stdin | `cmd <<< "$var"` |
| Encadenar comandos | `cmd1 \| cmd2 \| cmd3` |
| Usar la salida como *argumentos* | `cmd1 \| xargs cmd2` |
| Manejar nombres de archivo con espacios | `find … -print0 \| xargs -0 …` |
| Evitar ejecutar con entrada vacía | `xargs -r` |
| Una invocación por ítem | `xargs -I{} cmd {} extra` |
| Detectar una etapa fallida en una tubería | `set -o pipefail` / `${PIPESTATUS[@]}` |

**Distinciones de mayor rendimiento:** `>` trunca mientras que `>>` añade; `2>&1` debe ir *después* de la redirección de stdout; `|` conecta stdout→stdin mientras que `xargs` convierte stdout→argv; `tee` es la única forma estándar de satisfacer "pantalla **y** archivo" en una sola pasada; `&>`, `<<<` y `<(…)` son extensiones de bash, no POSIX.

---

## 11. Referencias

**Objetivos de certificación**
- LPI — Exam 101 Objectives (LPIC-1 versión 5.0), Tema 103.4: https://www.lpi.org/our-certifications/exam-101-objectives/
- LPI — Descripción general de la certificación LPIC-1: https://www.lpi.org/our-certifications/lpic-1-overview/

**Shell y estándares**
- GNU Bash Reference Manual — Redirections: https://www.gnu.org/software/bash/manual/html_node/Redirections.html
- GNU Bash Reference Manual — Pipelines: https://www.gnu.org/software/bash/manual/html_node/Pipelines.html
- GNU Bash Reference Manual — Process Substitution: https://www.gnu.org/software/bash/manual/html_node/Process-Substitution.html
- GNU Bash Reference Manual — The Set Builtin (`pipefail`, `noclobber`): https://www.gnu.org/software/bash/manual/html_node/The-Set-Builtin.html
- POSIX.1-2024 (IEEE Std 1003.1-2024) — Shell Command Language, Redirection: https://pubs.opengroup.org/onlinepubs/9799919799/utilities/V3_chap02.html#tag_19_07

**Kernel y libc**
- `pipe(7)` — tuberías y FIFOs, capacidad y `PIPE_BUF`: https://man7.org/linux/man-pages/man7/pipe.7.html
- `fifo(7)` — tuberías con nombre: https://man7.org/linux/man-pages/man7/fifo.7.html
- `dup(2)` / `dup2(2)`: https://man7.org/linux/man-pages/man2/dup.2.html
- `open(2)` — `O_APPEND`, `O_TRUNC`, `O_CREAT`: https://man7.org/linux/man-pages/man2/open.2.html
- `execve(2)` — `E2BIG` y `ARG_MAX`: https://man7.org/linux/man-pages/man2/execve.2.html
- `stdio(3)` — modos de buffering: https://man7.org/linux/man-pages/man3/stdio.3.html
- `setvbuf(3)`: https://man7.org/linux/man-pages/man3/setvbuf.3.html
- `proc(5)` — `/proc/pid/fd`, `/proc/pid/fdinfo`, `/proc/pid/wchan`: https://man7.org/linux/man-pages/man5/proc.5.html

**Utilidades básicas**
- GNU Coreutils Manual — `tee`: https://www.gnu.org/software/coreutils/manual/html_node/tee-invocation.html
- GNU Coreutils Manual — `stdbuf`: https://www.gnu.org/software/coreutils/manual/html_node/stdbuf-invocation.html
- GNU Findutils Manual — `xargs`: https://www.gnu.org/software/findutils/manual/html_node/find_html/Invoking-xargs.html
- GNU Findutils Manual — `find … -exec … +`: https://www.gnu.org/software/findutils/manual/html_node/find_html/Multiple-Files.html
- POSIX.1-2024 — `xargs`: https://pubs.opengroup.org/onlinepubs/9799919799/utilities/xargs.html
- POSIX.1-2024 — `tee`: https://pubs.opengroup.org/onlinepubs/9799919799/utilities/tee.html
- moreutils (`sponge`): https://joeyh.name/code/moreutils/

**Gestión de servicios y logging**
- systemd — `systemd.exec(5)`, `StandardInput=`/`StandardOutput=`/`StandardError=`: https://www.freedesktop.org/software/systemd/man/latest/systemd.exec.html
- systemd — `journald.conf(5)`: https://www.freedesktop.org/software/systemd/man/latest/journald.conf.html
- logrotate — `logrotate(8)`: https://linux.die.net/man/8/logrotate

**Contenedores y orquestación**
- Kubernetes — Arquitectura de logging (logging a nivel de nodo, formato de log CRI, sidecars): https://kubernetes.io/docs/concepts/cluster-administration/logging/
- Kubernetes — Determinar el motivo de la falla de un Pod (`terminationMessagePath`): https://kubernetes.io/docs/tasks/debug/debug-application/determine-reason-pod-failure/
- Kubernetes — Contenedores sidecar: https://kubernetes.io/docs/concepts/workloads/pods/sidecar-containers/
- Docker — Configurar drivers de logging: https://docs.docker.com/engine/logging/configure/
- The Twelve-Factor App — XI. Logs: https://12factor.net/logs