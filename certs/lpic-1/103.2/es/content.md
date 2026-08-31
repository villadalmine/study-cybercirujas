# LPIC-1 · Examen 101-500 · Objetivo 103.2 — Procesar flujos de texto usando filtros

**Peso del examen: 3.12** (≈5% del 101-500) · **Versión 5.0** · Perfil: SRE / Arquitecto de Plataforma

**Utilidades en alcance:** `bzcat`, `cat`, `cut`, `head`, `less`, `md5sum`, `nl`, `od`, `paste`, `sed`, `sha256sum`, `sha512sum`, `sort`, `split`, `tail`, `tr`, `uniq`, `wc`, `xzcat`, `zcat`

---

## 1. Motivación: el pipeline es un plano de datos en streaming

Todo stack de observabilidad termina fallándote en el peor momento posible. El gateway de Loki está estrangulado, Elasticsearch está en estado rojo porque un rebalanceo de shards se comió el disco, o el incidente es anterior a la ventana de retención. Lo que siempre te queda es un nodo, una shell y un descriptor de archivo.

La propiedad arquitectónica que importa es esta: **un filtro Unix es un operador de streaming con memoria acotada**. `grep`, `cut`, `tr`, `sed`, `head` y `wc` procesan una entrada arbitrariamente grande con memoria residente O(1), porque mantienen como mucho un registro por vez. `sort` y `uniq` son las excepciones que confirman la regla — `sort` es un operador bloqueante (no puede emitir su primer byte hasta haber leído el último), y `uniq` es un operador *con ventana* de exactamente una línea. Saber en qué categoría cae cada herramienta es la diferencia entre un comando de triage que responde en 400 ms sobre un log de 40 GB y uno que mata tu nodo por OOM.

El problema de producción es concreto:

> Una capa de ingress regional está devolviendo 5xx en el 3% de los requests. El pipeline de logs está 40 minutos atrasado. Tenés SSH a tres nodos, cada uno con 12 GB de `access.log.*` rotados y comprimidos con xz. Necesitás: los upstreams más problemáticos, la cardinalidad de rutas de request, y una confirmación byte a byte de que la configuración que el nodo está ejecutando es la configuración que el repositorio GitOps dice que debería estar ejecutando — en menos de cinco minutos, sin descargar nada.

Eso es el Objetivo 103.2 de punta a punta. Nada en este tema es de juguete: `sha256sum -c` es lo que separa tu clúster de un artefacto adulterado, `sort -u` con `LC_ALL=C` es lo que hace determinístico el diff de dos inventarios de 10 millones de líneas, y malinterpretar SIGPIPE es lo que hace que tu pipeline terminado en `head` registre una alerta espuria de "broken pipe" todas las noches a las 02:00.

---

## 2. La mecánica de fondo: qué es realmente un filtro

### 2.1 El contrato

Un filtro es un proceso que:

1. lee bytes del **descriptor de archivo 0** (`stdin`) cuando no se le da un operando de archivo,
2. escribe resultados en **fd 1** (`stdout`),
3. escribe diagnósticos en **fd 2** (`stderr`), que *no* forma parte del pipeline,
4. termina con `0` en caso de éxito.

El operador `|` del shell llama a `pipe(2)`, `fork(2)` y `dup2(2)` de modo que el extremo de escritura del pipe del kernel se convierte en el fd 1 del proceso izquierdo y el extremo de lectura en el fd 0 del derecho. **Todas las etapas arrancan simultáneamente.** Un pipeline es concurrente, no secuencial — por eso `cmd | head -1` puede terminar antes de que `cmd` haya producido el 1% de su salida.

### 2.2 El buffer del pipe y la contrapresión

```
$ ulimit -p                      # pipe buffer in 512-byte blocks
8
$ cat /proc/sys/fs/pipe-max-size
1048576
```

El buffer de pipe del kernel es por defecto de **65536 bytes** (16 páginas). Cuando está lleno, el escritor se bloquea en `write(2)` — eso es la contrapresión, y es lo que evita que un pipeline `zcat huge.gz | sort` materialice el flujo descomprimido en RAM. La velocidad del consumidor gobierna la velocidad del productor. Podés inspeccionarlo en vivo:

```
$ zcat access.log.gz | sed 's/^/x/' | wc -l &
[1] 21847
$ ls -l /proc/21847/fd
total 0
lrwx------ 1 root root 64 Aug 26 03:12 0 -> 'pipe:[418822]'
lrwx------ 1 root root 64 Aug 26 03:12 1 -> 'pipe:[418823]'
lrwx------ 1 root root 64 Aug 26 03:12 2 -> /dev/pts/0
```

### 2.3 SIGPIPE, exit 141 y la alerta fantasma

Cuando una etapa aguas abajo cierra su extremo de lectura, la escritura aguas arriba recibe `SIGPIPE`. La disposición por defecto es la terminación, y el shell reporta `128 + 13 = 141`.

```
$ zcat access.log.gz | head -n 3 > /dev/null
$ echo "${PIPESTATUS[@]}"
141 0
```

`zcat` "falló". No falló — se le indicó que parara. Este es un comportamiento correcto y deseable, y es la causa más común de falsos positivos de fallo en health checks basados en shell:

```bash
set -o pipefail                 # now the pipeline's status is 141
zcat access.log.gz | head -n 3  # -> exit 141 -> your CronJob is marked Failed
```

El idioma seguro para producción es acotar `pipefail` o incluir 141 en la lista blanca:

```bash
set -euo pipefail
head_safe() {
  local rc=0
  { zcat "$1" | head -n 3; } || rc=$?
  case "$rc" in 0|141) return 0 ;; *) return "$rc" ;; esac
}
```

### 2.4 Buffering: por qué tu pipeline de streaming no muestra nada

El stdio de glibc es **con buffer de línea cuando el fd 1 es una TTY y con buffer completo (4 KiB) cuando es un pipe**. Esto rompe silenciosamente el tailing en vivo:

```
$ tail -F /var/log/nginx/access.log | cut -d' ' -f9 | uniq -c
# ...nothing for minutes, then a burst of 4 KiB
```

Arreglalo en la etapa culpable con `stdbuf`:

```
$ tail -F /var/log/nginx/access.log | stdbuf -oL cut -d' ' -f9 | uniq -c
      3 200
      1 502
```

`grep --line-buffered` y `sed -u` tienen equivalentes incorporados. `stdbuf` funciona haciendo `LD_PRELOAD` de `libstdbuf.so`, así que no tiene efecto sobre binarios enlazados estáticamente ni sobre programas que fijan su propio buffering (`dd`, `tee` no se ven afectados por diseño).

### 2.5 Locale: el bug de corrección invisible

`sort`, `tr`, `uniq -i` y las clases de caracteres son todos sensibles al locale. Bajo `en_US.UTF-8`, el `sort` de GNU ignora la puntuación y las mayúsculas en su colación; bajo `C`/`POSIX` compara bytes crudos.

```
$ printf 'Zebra\napple\n_lib\nApple\n' | LC_ALL=en_US.UTF-8 sort
apple
Apple
_lib
Zebra
$ printf 'Zebra\napple\n_lib\nApple\n' | LC_ALL=C sort
Apple
Zebra
_lib
apple
```

Consecuencias con las que vas a chocar en producción:

- `comm`, `join` y `uniq` requieren entrada ordenada **con la misma colación con la que fueron construidas**. Mezclar locales produce operaciones de conjunto silenciosamente incorrectas — sin error, simplemente faltan filas.
- El orden de bytes (`LC_ALL=C`) es el único ordenamiento reproducible entre distribuciones, imágenes de contenedor y runners de CI. **Todo sort estable a checksum y diffeable debe fijar `LC_ALL=C`.**
- `LC_ALL=C` también es 2–5× más rápido, porque evita `strcoll(3)` en favor de `memcmp(3)`.

---

## 3. El catálogo, con encuadre de producción

### 3.1 Concatenación e inspección: `cat`, `nl`, `od`

`cat` concatena. Sus flags útiles para diagnóstico:

```
$ cat -A config.env
API_URL=https://api.internal:8443$
TIMEOUT=30^M$
  DEBUG=1$
$
```

`-A` = `-vET`: `$` marca el fin de línea, `^M` es CR (un fin de línea de Windows que va a hacer que tu parser de configuración produzca `"30\r"`), `^I` marcaría un tabulador. `-s` comprime líneas en blanco, `-n` numera todas las líneas, `-b` numera las líneas no vacías.

**Evitá el uso inútil de cat.** `cat file | grep x` bifurca un proceso extra y hace que `grep` pierda la capacidad de nombrar el archivo; escribí `grep x file` o `< file grep x`. Los usos legítimos de `cat` son: concatenar ≥2 archivos, alimentar stdin a un programa que no puede abrir archivos, y `cat -A`.

`nl` es un filtro de numeración con semántica de secciones que `cat -n` no tiene:

```
$ printf 'alpha\n\nbeta\n' | nl
     1  alpha

     2  beta
$ printf 'alpha\n\nbeta\n' | nl -b a -w 3 -s ': ' -n rz
001: alpha
002: 
003: beta
```

| Flag | Significado | Valores |
|---|---|---|
| `-b` | qué líneas del cuerpo numerar | `a` todas, `t` no vacías (por defecto), `n` ninguna, `pREGEX` las que coincidan |
| `-n` | formato del número | `ln` izquierda, `rn` derecha (por defecto), `rz` derecha con ceros a la izquierda |
| `-w` | ancho del número | por defecto `6` |
| `-s` | separador | por defecto `\t` |
| `-v` | primer número | por defecto `1` |
| `-i` | incremento | por defecto `1` |

`od` (octal dump) es la herramienta a la que recurrís cuando un archivo "se ve idéntico" pero se comporta distinto. **En la práctica casi siempre querés `-c` o `-A x -t x1z`:**

```
$ printf 'GET /health\xc2\xa0HTTP/1.1\r\n' | od -c
0000000   G   E   T       /   h   e   a   l   t   h 302 240   H   T   T
0000020   P   /   1   .   1  \r  \n
0000027
$ printf 'GET /health\xc2\xa0HTTP/1.1\r\n' | od -A x -t x1z -v
000000 47 45 54 20 2f 68 65 61 6c 74 68 c2 a0 48 54 54  >GET /health..HTT<
000010 50 2f 31 2e 31 0d 0a                             >P/1.1..<
000017
```

`c2 a0` es U+00A0 NO-BREAK SPACE — copiado y pegado de una wiki a un manifiesto, invisible en todo editor, y la razón por la que tu health check da 404. `-v` desactiva la compresión de repeticiones con `*`; sin él, las secuencias largas de bytes idénticos se colapsan y los offsets se vuelven confusos.

| Opción de `od` | Efecto |
|---|---|
| `-c` | caracteres imprimibles + escapes de C (la lectura humana más rápida) |
| `-t x1` / `-t x2` / `-t x4` | hexadecimal, 1/2/4 bytes por unidad |
| `-t d1`, `-t u1`, `-t o1` | decimal con signo/sin signo, octal |
| `-A d\|o\|x\|n` | base de la dirección; `n` suprime los offsets |
| `-z` | agrega la columna ASCII al margen |
| `-N BYTES`, `-j BYTES` | leer solo N bytes / saltear los primeros N |
| `-v` | no comprimir líneas duplicadas |

### 3.2 Extracción de columnas: `cut` y `paste`

`cut` es el extractor de campos más barato que existe — una sola pasada, sin motor de regex, sin división de campos por secuencias.

```
$ cut -d: -f1,7 /etc/passwd | head -n 4
root:/bin/bash
daemon:/usr/sbin/nologin
bin:/usr/sbin/nologin
sys:/usr/sbin/nologin
$ cut -d: -f3 --output-delimiter=' | ' -f1,3 /etc/passwd | head -n 2
root | 0
daemon | 1
$ echo 'kube-apiserver-node01' | cut -c1-14
kube-apiserver
$ cut -d: -f1 --complement /etc/passwd | head -n 1
x:0:0:root:/root:/bin/bash
```

**La trampa que explotan tanto el examen como la producción:** `cut -d' '` trata *cada* espacio como delimitador, así que las secuencias de espacios crean campos vacíos. La salida de `ls -l` y `ps` no es, por lo tanto, directamente procesable con `cut`:

```
$ ls -l /etc/hosts | cut -d' ' -f5
                      # empty — field 5 is one of the padding spaces
$ ls -l /etc/hosts | tr -s ' ' | cut -d' ' -f5
221
```

`tr -s ' '` (squeeze) es el pre-normalizador canónico. Los datos delimitados por tabuladores no tienen ese problema, y por eso `-d$'\t'` (el valor por defecto de `cut`) es seguro.

| Selector | Unidad | ¿Seguro con multibyte? |
|---|---|---|
| `-b LIST` | bytes | no — parte las secuencias UTF-8 |
| `-c LIST` | caracteres | sí en un locale UTF-8 |
| `-f LIST` | campos separados por delimitador | n/a |

`LIST` acepta `N`, `N-`, `-M`, `N-M`, y listas separadas por comas. **El orden se ignora**: `cut -f3,1` emite el campo 1 y después el 3. Si necesitás reordenar, `cut` es la herramienta equivocada.

`paste` es el inverso de `cut` — una fusión por columnas:

```
$ cut -d: -f1 /etc/passwd | head -3 > /tmp/u
$ cut -d: -f7 /etc/passwd | head -3 > /tmp/s
$ paste -d' -> ' /tmp/u /tmp/s
root -> /bin/bash
daemon -> /usr/sbin/nologin
bin -> /usr/sbin/nologin
```

La lista de delimitadores cicla por columna. `-s` (serial) transpone una columna en una fila — el idioma para convertir una lista de archivos en un argumento CSV:

```
$ kubectl get ns -o name | cut -d/ -f2 | paste -sd,
default,kube-system,kube-public,ingress-nginx,observability
$ paste -sd'\n\n' /tmp/u        # cycle delimiters to double-space
```

### 3.3 Ventaneo: `head`, `tail`, `less`

```
$ head -n 5 /var/log/syslog
$ head -c 512 /boot/vmlinuz | od -A d -t x1 | head -n 2
0000000 4d 5a ea 07 00 c0 07 8c c8 8e d8 8e c0 8e d0 31
0000016 e4 8e d4 fb fc be 40 00 ac 20 c0 74 09 b4 0e bb
$ tail -n 20 /var/log/nginx/error.log
$ tail -n +100 access.log        # from line 100 to EOF (note the +)
$ head -n -5 report.txt          # all but the LAST 5 lines (GNU only)
```

| Forma | `head` | `tail` |
|---|---|---|
| `-n N` | las primeras N líneas | las últimas N líneas |
| `-n +N` | (GNU) todas menos las últimas N es `-n -N` | desde la línea N en adelante |
| `-n -N` | todas menos las últimas N líneas | (GNU) todas menos las primeras N es `-n +N` |
| `-c N` | los primeros N bytes | los últimos N bytes |
| `-q` / `-v` | suprimir / forzar los encabezados con nombre de archivo | igual |

`head -n -N` y `tail -n +N` requieren ambos buffering o seeking — `tail -n +N` hace streaming, `head -n -N` debe mantener un buffer circular de N líneas.

**`tail -f` vs `tail -F` es una distinción de nivel SRE:**

- `-f` sigue el **inodo**. Cuando logrotate renombra `access.log` → `access.log.1` y crea un archivo nuevo, `-f` sigue leyendo el inodo viejo ahora invisible. Tu dashboard se queda mudo y nadie lo nota durante seis horas.
- `-F` = `--follow=name --retry`. Vuelve a hacer `open(2)` por ruta cuando detecta rotación o truncamiento, y espera a que el archivo reaparezca.

```
$ tail -F /var/log/nginx/access.log
tail: '/var/log/nginx/access.log' has become inaccessible: No such file or directory
tail: '/var/log/nginx/access.log' has appeared;  following new file
10.42.0.7 - - [26/Aug/2026:03:14:02 +0000] "GET /healthz HTTP/1.1" 200 2
```

Dos flags más que importan en supervisores y sidecars:

```
$ tail -F --pid=$(pidof nginx) /var/log/nginx/error.log   # exit when nginx dies
$ tail -f -s 5 /var/log/audit/audit.log                   # poll interval (inotify is used when available)
```

En un nodo con muchos archivos seguidos podés agotar `fs.inotify.max_user_watches`; el tail de GNU cae a polling y registra `inotify cannot be used, reverting to polling`.

`less` es un paginador, no un filtro, pero está en el objetivo y es donde ocurre realmente el triage:

| Tecla | Acción |
|---|---|
| `/pat` `?pat` | buscar hacia adelante / hacia atrás |
| `n` `N` | coincidencia siguiente / anterior |
| `&pat` | **mostrar solo las líneas coincidentes** (un grep en vivo dentro del paginador) |
| `F` | modo seguimiento, equivalente a `tail -f`; `Ctrl-C` vuelve a la paginación |
| `g` `G` | primera / última línea |
| `-N` | mostrar números de línea |
| `-S` | cortar las líneas largas en vez de envolverlas |
| `-X` | no limpiar la pantalla al salir |
| `+F`, `+G`, `+/pat` | arrancar en modo seguimiento / en EOF / en la primera coincidencia |
| `q` | salir |

```
$ less +F /var/log/nginx/access.log
$ zcat access.log.4.gz | less -SN
```

`less` no está restringido a entrada seekable, así que funciona en medio de un pipeline; `LESSOPEN` le permite descomprimir de forma transparente (`less access.log.gz` ya funciona en la mayoría de las distribuciones vía `lesspipe`).

### 3.4 Ordenamiento y deduplicación: `sort` y `uniq`

`sort` es el único operador bloqueante de este objetivo. Lee todo, vuelca a `TMPDIR` cuando se excede el buffer en memoria, y fusiona las corridas.

```
$ sort -t: -k3,3n /etc/passwd | tail -n 3
sshd:x:74:74:Privilege-separated SSH:/var/empty/sshd:/sbin/nologin
prometheus:x:65534:65534::/var/lib/prometheus:/sbin/nologin
nobody:x:65534:65534:Kernel Overflow User:/:/sbin/nologin
$ du -sh /var/log/* | sort -h | tail -n 3
124M    /var/log/journal
1.2G    /var/log/nginx
3.4G    /var/log/containers
$ printf 'v1.10.0\nv1.9.3\nv1.2.0\n' | sort -V
v1.2.0
v1.9.3
v1.10.0
```

**La sintaxis de las claves es la parte que la gente hace mal.** `-k F[.C][OPTS][,F[.C][OPTS]]`. Si omitís el campo final, la clave se extiende *hasta el final de la línea* — así que `-k3n` sobre `/etc/passwd` ordena por "campo 3 hasta el fin de línea, interpretado numéricamente", que no es lo que querías decir. **Escribí siempre una clave cerrada: `-k3,3n`.**

| Opción | Significado | Notas |
|---|---|---|
| `-t CHAR` | separador de campos | por defecto: la transición de no-blanco a blanco; los blancos iniciales pertenecen al campo *siguiente* |
| `-k F1,F2` | rango de la clave de ordenamiento | los modificadores por clave `n g h V r f b d i` anulan los globales |
| `-n` | numérico | solo blancos iniciales/signo/dígitos; `1e3` no es numérico |
| `-g` | numérico general (`strtod`) | maneja `1e3`, `inf`; más lento, pérdida de precisión de punto flotante |
| `-h` | numérico humano | `1K < 1M < 1G`; coincide con `du -h`, `ls -lh` |
| `-V` | ordenamiento de versiones | `1.10 > 1.9` |
| `-M` | ordenamiento por mes | depende del locale |
| `-r` | invertido | |
| `-u` | emitir solo el primero de una corrida de claves iguales | **compara claves, no líneas completas** |
| `-s` | estable | desactiva la comparación de último recurso por línea completa |
| `-b` | ignorar blancos iniciales | debe ser por clave para ser confiable |
| `-f` | plegar mayúsculas/minúsculas | |
| `-z` | registros terminados en NUL | se combina con `find -print0` |
| `-c` / `-C` | verificar si está ordenado (exit 1 si no) | `-C` es silencioso |
| `-m` | fusionar entradas ya ordenadas | O(n) en vez de O(n log n) |
| `-S SIZE` | buffer de memoria (`-S 2G`, `-S 50%`) | |
| `-T DIR` | directorio temporal para los volcados | |
| `--parallel=N` | hilos de trabajo | por defecto = cantidad de núcleos |
| `--compress-program=zstd` | comprimir los archivos de volcado | gran ganancia en ordenamientos grandes con discos lentos |

La sutileza de `-u`, que muerde en trabajos de deduplicación:

```
$ printf 'a 1\na 2\nb 1\n' | sort -k1,1 -u
a 1
b 1
```

Solo se comparó la *clave*, así que `a 2` se descartó. Usá `sort -u` sin `-k`, o `sort | uniq`, cuando querés decir "líneas distintas".

`uniq` colapsa solo duplicados **adyacentes**. Es un filtro con ventana de una línea, que es exactamente por qué usa memoria O(1) y por qué requiere entrada ordenada:

```
$ printf 'a\nb\na\n' | uniq
a
b
a
$ printf 'a\nb\na\n' | sort | uniq -c
      2 a
      1 b
```

| Opción | Significado |
|---|---|
| `-c` | prefija cada corrida con su cuenta (`%7d ` — alineado a la derecha en 7 columnas) |
| `-d` | solo las líneas que se repiten (una por grupo) |
| `-D` | *todas* las líneas de los grupos repetidos |
| `-u` | solo las líneas que ocurren exactamente una vez |
| `-i` | sin distinguir mayúsculas/minúsculas |
| `-f N` | saltear los primeros N campos al comparar |
| `-s N` | saltear los primeros N caracteres al comparar |
| `-w N` | comparar como mucho N caracteres |
| `-z` | terminado en NUL |

`-f`/`-s`/`-w` son lo que hace usable a `uniq` sobre logs con marca de tiempo, donde el prefijo difiere pero el mensaje no:

```
$ cut -d' ' -f1-3 --complement /var/log/syslog | sort | uniq -c | sort -rn | head -n 5
   4127 kernel: [UFW BLOCK] IN=eth0 OUT= MAC=...
    918 systemd[1]: Started Session c2 of user deploy.
    311 kubelet[1442]: E0826 03:14:02.118 pod_workers.go:190] Error syncing pod
     44 sshd[2288]: Failed password for invalid user admin from 45.83.64.7
      9 nginx[901]: upstream timed out (110: Connection timed out)
```

**`sort | uniq -c | sort -rn | head` es el idioma del top-N.** Grabátelo en la memoria muscular; responde "qué está inundando mis logs" en todos los incidentes.

### 3.5 Conteo: `wc`

```
$ wc /etc/services
 11473  62139 692252 /etc/services
$ wc -l /var/log/nginx/access.log
2841903 /var/log/nginx/access.log
$ printf 'no trailing newline' | wc -l
0
$ printf 'no trailing newline' | wc -c
19
```

| Flag | Cuenta |
|---|---|
| `-l` | **caracteres de nueva línea** (no "líneas") |
| `-w` | palabras delimitadas por espacios en blanco |
| `-c` | bytes |
| `-m` | caracteres (según el locale; difiere de `-c` en UTF-8) |
| `-L` | longitud de la línea más larga (ancho de visualización) |

Que `wc -l` cuente saltos de línea en vez de líneas es una fuente real de defectos: un log truncado cuyo registro final no tiene `\n` se cuenta uno de menos, y un pipeline que reporta `0` registros para un archivo de un solo registro va a saltear el procesamiento en silencio. Cuando la exactitud importa, `grep -c ''` cuenta las líneas incluyendo una última sin terminar.

`-m` vs `-c` es el chequeo de UTF-8:

```
$ printf 'año\n' | wc -c -m
4 5      # -m=4 chars, -c=5 bytes  (output order is line,word,char,byte per POSIX)
```

### 3.6 Transformación a nivel de carácter: `tr`

`tr` traduce, comprime y elimina **caracteres** — nunca cadenas. Lee solo de stdin (no acepta operandos de archivo).

```
$ echo 'Prod-Cluster-EU' | tr 'A-Z' 'a-z'
prod-cluster-eu
$ echo 'Prod-Cluster-EU' | tr '[:upper:]' '[:lower:]'      # locale-correct form
prod-cluster-eu
$ cat -A config.env | head -n 1
TIMEOUT=30^M$
$ tr -d '\r' < config.env > config.env.fixed
$ ls -l | tr -s ' ' | cut -d' ' -f5,9
221 hosts
$ head -c 32 /dev/urandom | tr -dc 'A-Za-z0-9' ; echo
7fQx2LmZ9pKdR4vT
$ echo 'a:b:c' | tr ':' '\n'
a
b
c
```

| Flag | Efecto |
|---|---|
| `-d SET1` | eliminar todos los caracteres de SET1 |
| `-s SET` | comprimir a uno los caracteres adyacentes repetidos de SET |
| `-c` / `-C` | complementar SET1 (operar sobre todo lo que *no* está en él) |
| `-t` | truncar SET1 a la longitud de SET2 |

Clases de caracteres: `[:alpha:] [:digit:] [:alnum:] [:space:] [:blank:] [:upper:] [:lower:] [:punct:] [:print:] [:graph:] [:cntrl:] [:xdigit:]`. Escapes: `\n \r \t \\ \NNN` (octal). Rangos: `a-z`, `\000-\037`.

**Reglas de dimensionamiento:** si SET2 es más corto que SET1, el `tr` de GNU rellena SET2 con su último carácter (POSIX lo declara indefinido; `-t` en cambio trunca SET1). `[:upper:]`→`[:lower:]` es el único mapeo de clase a clase cuyo funcionamiento está garantizado.

**Lo que `tr` no puede hacer:** reemplazar `"foo"` por `"bar"`. `tr foo bar` mapea f→b, o→a, o→r. Para reemplazo de cadenas necesitás `sed`. Y `tr -d` sobre caracteres multibyte opera sobre bytes en la mayoría de las implementaciones, así que `tr -d 'ñ'` puede corromper UTF-8 — usá `sed 's/ñ//g'` en su lugar.

Sanitizar texto de log no confiable antes de que llegue a una terminal (defensivo: previene la inyección de secuencias ANSI en tu scrollback):

```
$ tr -d '\000-\010\013\014\016-\037\177' < untrusted.log | less
```

### 3.7 El editor de flujos: `sed`

`sed` lee una línea al **espacio de patrones**, aplica el script, imprime el espacio de patrones salvo que se use `-n`, y repite. Un **espacio de retención** separado persiste entre ciclos. Ese es todo el modelo de ejecución.

```
$ sed 's/upstream/backend/' error.log | head -n 1
2026/08/26 03:14:02 [error] 901#901: *18 backend timed out
$ sed 's/[0-9]\{1,3\}\.[0-9]\{1,3\}\.[0-9]\{1,3\}\.[0-9]\{1,3\}/REDACTED/g' access.log | head -n 1
REDACTED - - [26/Aug/2026:03:14:02 +0000] "GET /healthz HTTP/1.1" 200 2
$ sed -E 's/([0-9]{1,3}\.){3}[0-9]{1,3}/REDACTED/g' access.log | head -n 1
REDACTED - - [26/Aug/2026:03:14:02 +0000] "GET /healthz HTTP/1.1" 200 2
```

**Las direcciones** seleccionan a qué líneas se aplica un comando:

| Dirección | Selecciona |
|---|---|
| `5` | la línea 5 |
| `5,10` | las líneas 5–10 |
| `5,+3` | la línea 5 y las 3 siguientes |
| `0~3` | cada 3ª línea (forma de paso de GNU) |
| `$` | la última línea |
| `/regex/` | las líneas coincidentes |
| `/start/,/end/` | desde el primer `start` hasta el siguiente `end` (puede volver a dispararse) |
| `/regex/!` | negación |
| `5,$` | de la línea 5 al EOF |

**Comandos:**

| Comando | Efecto |
|---|---|
| `s/RE/REPL/FLAGS` | sustituir; flags `g` (todas), `N` (la N-ésima), `p` (imprimir), `i` (ignorar mayúsculas), `w FILE` |
| `d` | eliminar el espacio de patrones, empezar el ciclo siguiente |
| `p` | imprimir el espacio de patrones (combinar con `-n`) |
| `q [EXIT]` | salir, opcionalmente con un código de salida |
| `a TEXT` / `i TEXT` / `c TEXT` | agregar después / insertar antes / cambiar la línea |
| `y/abc/xyz/` | transliterar (un `tr` para una línea) |
| `n` / `N` | leer la línea siguiente (reemplazando / agregando al espacio de patrones) |
| `h H g G x` | espacio de retención: copiar a / agregar a / copiar desde / agregar desde / intercambiar |
| `=` | imprimir el número de línea actual |
| `r FILE` / `R FILE` | leer el archivo entero / una línea de él |
| `{ ...; ... }` | agrupar comandos bajo una sola dirección |

En el reemplazo, `&` es la coincidencia completa, `\1`–`\9` son los grupos de captura, y GNU agrega `\U \L \u \l \E` para conversión de mayúsculas/minúsculas:

```
$ echo 'pod-frontend-7d9' | sed -E 's/^pod-(\w+)-.*/\U\1/'
FRONTEND
```

**Flags de rendimiento que importan a escala.** `sed` lee hasta EOF por defecto. En un archivo de 40 GB, `sed -n '2000000p'` lee los 40 GB completos. Agregá `q`:

```
$ time sed -n '2000000p' huge.log
...
real    0m11.402s
$ time sed -n '2000000{p;q}' huge.log
...
real    0m0.318s
```

**`-i` no es una escritura in situ.** El `sed -i` de GNU crea un archivo temporal en el mismo directorio, lo escribe, y hace `rename(2)` sobre el original. Implicancias que tenés que prever en producción:

- El **inodo cambia**. Cualquier proceso que tenga el fd viejo (`tail -f`, un demonio en ejecución) sigue leyendo el contenido viejo.
- **Los enlaces duros se rompen** — los otros nombres siguen apuntando al inodo viejo.
- **Los bind mounts de archivos individuales dentro de contenedores fallan**: `sed: cannot rename /etc/nginx/nginx.conf: Device or resource busy`, porque el destino del montaje no puede reemplazarse. Escribí a una ruta temporal y usá `cat > file` en su lugar.
- Los contextos SELinux y las ACL no predeterminadas pueden no preservarse. `--follow-symlinks` es necesario si el destino es un enlace simbólico; de lo contrario el enlace se reemplaza por un archivo regular.

```
$ sed -i.bak 's/worker_processes 1;/worker_processes auto;/' /etc/nginx/nginx.conf
$ ls /etc/nginx/nginx.conf*
/etc/nginx/nginx.conf  /etc/nginx/nginx.conf.bak
```

Tomá siempre el `.bak` en una configuración en vivo, y validá siempre antes de recargar (`nginx -t`).

### 3.8 División: `split`

```
$ split -l 500000 -d -a 3 --additional-suffix=.log access.log chunk_
$ ls
chunk_000.log  chunk_001.log  chunk_002.log  chunk_003.log  chunk_004.log  chunk_005.log
$ wc -l chunk_*.log | tail -n 1
2841903 total
```

| Opción | Efecto |
|---|---|
| `-l N` | N líneas por archivo de salida |
| `-b SIZE` | N bytes por archivo (`10M`, `1G`, `512K`) |
| `-C SIZE` | como mucho SIZE bytes, pero sin partir nunca una línea |
| `-n N` | exactamente N archivos (división por bytes; puede partir líneas) |
| `-n l/N` | N archivos, alineados a líneas |
| `-n r/N` | líneas en round-robin entre N archivos |
| `-n l/K/N` | escribir solo el fragmento K de N a stdout — sin archivos temporales |
| `-d` / `-x` | sufijos numéricos / hexadecimales |
| `-a N` | longitud del sufijo (por defecto 2 → 676 archivos con sufijos alfabéticos) |
| `--additional-suffix=.ext` | conservar la extensión |
| `--filter='CMD'` | canalizar cada fragmento por CMD en vez de escribirlo |
| `-u` | sin buffer (para dividir un flujo en vivo) |

Dos patrones de producción que vale la pena memorizar:

```
# Parallel-process a huge log without ever writing chunks to disk
$ split -n l/8 --filter='sort -u > /tmp/part_$FILE' access.log part_

# Split and compress on the fly (no intermediate uncompressed files)
$ split -b 1G --filter='xz -T0 -c > $FILE.xz' backup.tar backup.part_

# Extract exactly the 3rd eighth of a file, streaming
$ split -n l/3/8 access.log | wc -l
355238
```

El agotamiento de sufijos es un fallo real: `split -l 1000` sobre un archivo de 700 000 líneas con el `-a 2` por defecto muere con `split: output file suffixes exhausted` después de `zz`. GNU aumenta automáticamente la longitud del sufijo cuando no se da `-a`, pero los scripts que fijan `-a 2` se van a romper a medida que los datos crezcan.

### 3.9 Integridad: `md5sum`, `sha256sum`, `sha512sum`

```
$ sha256sum kubectl
b2e2f6cbbecb70f5cba0ba97b7e64ae7d61f9c7e60b0e88bea25ecfa1f7f9b3f  kubectl
$ sha256sum kubectl > kubectl.sha256
$ sha256sum -c kubectl.sha256
kubectl: OK
$ printf 'x' >> kubectl
$ sha256sum -c kubectl.sha256
kubectl: FAILED
sha256sum: WARNING: 1 computed checksum did NOT match
$ echo $?
1
```

El separador de dos espacios es significativo: **dos espacios = modo binario/texto, espacio-asterisco (` *`) = modo binario**. GNU coreutils trata a ambos de forma idéntica en Linux (sin traducción de CRLF), pero un archivo generado en Windows con ` *` va a verificarse correctamente igual.

| Opción | Efecto |
|---|---|
| `-c FILE` | verificar los checksums listados en FILE |
| `--status` | sin salida; **comunica el resultado solo por el código de salida** |
| `--quiet` | imprimir solo los fallos |
| `--ignore-missing` | no fallar por archivos ausentes (verificar un subconjunto de un manifiesto grande) |
| `--strict` | terminar con código distinto de cero ante líneas mal formadas en el archivo de checksums |
| `--tag` | emitir el estilo BSD `SHA256 (file) = hash` |
| `-b` / `-t` | marcador de modo binario / texto |
| `-z` | salida terminada en NUL (segura para nombres de archivo con saltos de línea) |

Códigos de salida de `-c`: `0` todo coincidió; `1` al menos una discrepancia, archivo faltante o ilegible; `2` error de uso o un archivo de checksums sin líneas válidas. `--strict` promueve las líneas mal formadas a fallo — **usalo en CI**, porque de lo contrario un manifiesto truncado se verifica "exitosamente" contra cero archivos.

```
$ sha256sum --status -c SHA256SUMS --strict || { echo "SUPPLY CHAIN FAILURE"; exit 1; }
```

| Algoritmo | Digest | Velocidad (relativa) | Resistencia a colisiones | Usalo para |
|---|---|---|---|---|
| `md5sum` | 128 bits | el más rápido | **roto** (colisiones prácticas de prefijo elegido, 2009/2019) | solo detección de corrupción accidental, manifiestos heredados de proveedores |
| `sha1sum` | 160 bits | rápido | **roto** (SHAttered 2017, prefijo elegido 2020) | IDs de objetos git heredados; nunca para nuevas barreras de integridad |
| `sha256sum` | 256 bits | rápido (con `sha_ni` por hardware en x86 moderno) | estándar actual | **el valor por defecto para artefactos, imágenes, bundles de IaC** |
| `sha512sum` | 512 bits | a menudo más rápido que SHA-256 en CPUs de 64 bits *sin* extensiones SHA | estándar actual | archivos grandes en hardware sin `sha_ni`, pipelines con FIPS obligatorio |
| `sha512sum -a 224/256` (`sha224sum`, `shasum -a`) | truncado | como SHA-512 | estándar actual | cuando se requiere un digest más corto |

Verificá si tu CPU acelera SHA-256:

```
$ grep -o -m1 'sha_ni' /proc/cpuinfo
sha_ni
$ openssl speed -evp sha256 2>/dev/null | tail -n 2
```

**Encuadre de seguridad crítico:** un checksum prueba *integridad*, no *autenticidad*. Si el atacante puede reescribir el artefacto, puede reescribir `SHA256SUMS` junto con él. El archivo de hashes debe entregarse por un canal de confianza separado — una firma GPG desprendida (`gpg --verify SHA256SUMS.asc SHA256SUMS`), una atestación de sigstore/cosign, o un digest fijado en un manifiesto firmado en Git. `sha256sum -c` es el *último* eslabón de esa cadena, no la cadena entera.

### 3.10 Flujos comprimidos: `zcat`, `bzcat`, `xzcat`

Los tres son filtros que descomprimen a stdout, así que se insertan en un pipeline sin escribir nunca un archivo temporal en texto plano — lo cual importa cuando el log pesa 12 GB y `/tmp` tiene 2 GB.

```
$ zcat /var/log/nginx/access.log.2.gz | wc -l
1204817
$ xzcat /var/log/nginx/access.log.9.xz | cut -d' ' -f9 | sort | uniq -c | sort -rn
 982411 200
  41209 304
   3877 502
    118 499
$ zcat access.log.*.gz | ...       # zcat concatenates multiple members/files
$ bzcat backup-2026-08.tar.bz2 | tar -tvf - | head -n 3
```

`zcat` es `gunzip -c`. Notá que el `zcat` de GNU también maneja archivos `.Z` (compress); **no** maneja `.bz2` ni `.xz`. Hay una familia equivalente para cada uno: `zless`/`bzless`/`xzless`, `zgrep`/`bzgrep`/`xzgrep`, `zdiff`, `zmore`.

| Formato | Descompresor | Ratio típico (logs de texto) | Velocidad de descompresión | Costo de compresión | Apto para streaming | Notas |
|---|---|---|---|---|---|---|
| `.gz` (DEFLATE) | `zcat` | ~4–6× | muy rápida | bajo | sí | universal; `pigz` paraleliza la compresión, la descompresión es de un solo hilo |
| `.bz2` (BWT) | `bzcat` | ~5–7× | **lenta** | alto | sí (por bloques) | mayormente superado; `lbzip2`/`pbzip2` paralelizan |
| `.xz` (LZMA2) | `xzcat` | ~7–10× | moderada | muy alto | sí | el mejor ratio; `xz -T0` para comprimir en paralelo; alta RAM de descompresión con `-9` |
| `.zst` | `zstdcat` | ~5–7× | **la más rápida** | bajo–moderado | sí | no está en el objetivo de LPIC-1, pero es el valor por defecto actual en systemd-journald, Btrfs y los registries de contenedores |

Para el archivado de logs la regla práctica es: `zstd -19 --long` o `xz -6` para archivos fríos que rara vez leés, `gzip`/`zstd -3` para la ventana de rotación caliente que grepeás a diario. El `xz -9` de almacenamiento frío puede costar 700 MB de RAM para *descomprimir* — un descubrimiento desagradable en un contenedor limitado a 1 GB de memoria.

---

## 4. Tablas comparativas de decisión

### 4.1 Qué filtro para qué tarea

| Tarea | Recurrí a | Por qué no la alternativa |
|---|---|---|
| Extraer campos con delimitador fijo | `cut -d: -f1,7` | `sed`/`awk` cuestan un motor de regex por línea |
| Extraer campos separados por *secuencias* de espacios | `tr -s ' ' \| cut` | `cut` no puede colapsar secuencias |
| Reordenar o calcular sobre campos | `awk` (fuera del alcance del examen) | `cut` ignora el orden del selector |
| Reemplazar una cadena | `sed 's/a/b/g'` | `tr` mapea caracteres, no cadenas |
| Eliminar/comprimir/traducir caracteres | `tr` | `sed` es ~5–10× más lento para el mismo trabajo |
| Primeros/últimos N registros | `head` / `tail` | `sed -n '1,10p'` lee hasta EOF salvo que agregues `q` |
| Valores distintos | `sort -u` | `uniq` por sí solo solo ve duplicados adyacentes |
| Ranking de frecuencias | `sort \| uniq -c \| sort -rn` | no hay alternativa de una sola pasada en coreutils |
| Contar registros | `wc -l` | `grep -c ''` si la última línea puede no tener `\n` |
| Diagnóstico a nivel de bytes | `od -c` | todo editor esconde los bytes que están causando el bug |
| Fragmentar un archivo enorme | `split -n l/N` | el troceado manual con `head`/`tail` es O(n²) |
| Barrera de integridad | `sha256sum -c --strict --status` | `md5sum` no es resistente a colisiones |

### 4.2 Comportamiento de memoria y bloqueo

| Herramienta | Memoria residente | ¿Bloquea? | Primer byte de salida |
|---|---|---|---|
| `cat`, `tr`, `cut`, `nl`, `sed` (sin acumulación en el espacio de retención) | O(1) — una línea/buffer | no | inmediatamente |
| `head -n N` | O(1) | no | inmediatamente; termina antes → SIGPIPE aguas arriba |
| `tail -n N` | buffer circular de O(N líneas), o seek si es seekable | sí | después del EOF |
| `uniq` | O(1) — ventana de una línea | no | inmediatamente |
| `wc` | O(1) | sí (debe contar todo) | después del EOF |
| `sort` | O(n), vuelca a `-T` al pasar `-S` | **sí** | después del EOF |
| `sort -m` | O(cantidad de entradas) | no | inmediatamente |
| `split` | O(1) | no | inmediatamente |
| `sha256sum` | O(1) | sí | después del EOF |
| `zcat`/`xzcat`/`bzcat` | O(ventana/bloque) | no | inmediatamente |

La consecuencia operativa: **empujá `head`, `cut`, `grep` y `tr` lo más a la izquierda posible del pipeline, y `sort` lo más a la derecha posible.** Reducir la cardinalidad antes del operador bloqueante es la optimización de mayor apalancamiento en el procesamiento de datos con shell.

### 4.3 Medirlo vos mismo

No tomes los ratios por fe — el banco de pruebas de abajo es reproducible en tu propio hardware, y el ordenamiento, no los números absolutos, es la lección:

```bash
#!/usr/bin/env bash
# bench-filters.sh — quantify pipeline ordering and locale on YOUR node
set -euo pipefail
LOG=${1:?usage: bench-filters.sh <access.log>}

echo "== filter first, sort last =="
time (cut -d' ' -f7 "$LOG" | sort | uniq -c | sort -rn | head -20 >/dev/null)

echo "== sort first (anti-pattern) =="
time (sort "$LOG" | cut -d' ' -f7 | uniq -c | sort -rn | head -20 >/dev/null)

echo "== UTF-8 collation =="
time (LC_ALL=en_US.UTF-8 sort "$LOG" >/dev/null)

echo "== byte collation =="
time (LC_ALL=C sort "$LOG" >/dev/null)

echo "== sort tuned =="
time (LC_ALL=C sort -S 25% --parallel="$(nproc)" --compress-program=zstd "$LOG" >/dev/null)
```

Esperá que el ordenamiento filtro-primero domine aproximadamente por la razón entre el ancho de la línea completa y el ancho del campo extraído, y que `LC_ALL=C` recorte el tiempo de reloj del sort por un factor de alrededor de 2–5 en un sistema UTF-8. Registrá los números reales de tu flota; se convierten en la justificación cuando alguien pregunte por qué el runbook de triage fija `LC_ALL=C`.

---

## 5. Infraestructura de producción

### 5.1 Kubernetes: CronJob de triage de logs (manifiestos completos)

Esto se ejecuta enteramente con las herramientas de este objetivo — sin `awk`, sin binarios externos — contra un directorio de logs del nodo montado, y escribe un resumen compacto que un ingeniero de guardia puede leer en quince segundos.

```yaml
---
apiVersion: v1
kind: Namespace
metadata:
  name: ops-triage
  labels:
    pod-security.kubernetes.io/enforce: baseline
    pod-security.kubernetes.io/audit: restricted
---
apiVersion: v1
kind: ServiceAccount
metadata:
  name: log-triage
  namespace: ops-triage
automountServiceAccountToken: false
---
apiVersion: v1
kind: ConfigMap
metadata:
  name: log-triage-scripts
  namespace: ops-triage
data:
  triage.sh: |
    #!/usr/bin/env bash
    # Streaming ingress-log triage. Bounded memory, no temp files outside $TMPDIR.
    set -euo pipefail
    export LC_ALL=C                 # byte collation: deterministic + fast

    LOG_DIR=${LOG_DIR:-/var/log/nginx}
    OUT_DIR=${OUT_DIR:-/reports}
    TOP_N=${TOP_N:-20}
    STAMP=$(date -u +%Y%m%dT%H%M%SZ)
    REPORT="${OUT_DIR}/triage-${STAMP}.txt"

    # Decompress by extension; plain files pass through cat.
    stream() {
      local f
      for f in "$LOG_DIR"/access.log "$LOG_DIR"/access.log.*; do
        [ -e "$f" ] || continue
        case "$f" in
          *.gz)  zcat  -- "$f" ;;
          *.bz2) bzcat -- "$f" ;;
          *.xz)  xzcat -- "$f" ;;
          *)     cat   -- "$f" ;;
        esac
      done
    }

    # Combined log format field map (space-separated):
    #   1 remote_addr  4 [time_local  6 "request_method  7 request_uri  9 status
    {
      printf '=== ingress triage %s ===\n\n' "$STAMP"

      printf -- '--- total requests ---\n'
      stream | wc -l

      printf -- '\n--- status code distribution ---\n'
      stream | cut -d' ' -f9 | sort | uniq -c | sort -rn

      printf -- '\n--- top %s client addresses ---\n' "$TOP_N"
      stream | cut -d' ' -f1 | sort | uniq -c | sort -rn | head -n "$TOP_N"

      printf -- '\n--- top %s paths returning 5xx ---\n' "$TOP_N"
      stream \
        | sed -n '/" 5[0-9][0-9] /p' \
        | cut -d' ' -f7 \
        | sed 's/?.*$//' \
        | sort | uniq -c | sort -rn | head -n "$TOP_N"

      printf -- '\n--- requests per minute (last window) ---\n'
      stream | cut -d' ' -f4 | cut -c2-18 | uniq -c | tail -n 15

      printf -- '\n--- longest request lines (possible injection / overflow) ---\n'
      stream | wc -L
    } > "$REPORT"

    # Integrity anchor for the report itself: it will be shipped off-node.
    sha256sum "$REPORT" > "${REPORT}.sha256"
    sha256sum -c --strict --status "${REPORT}.sha256"

    printf 'report written: %s (%s bytes)\n' "$REPORT" "$(wc -c < "$REPORT")"
    head -n 40 "$REPORT"
---
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: triage-reports
  namespace: ops-triage
spec:
  accessModes:
    - ReadWriteOnce
  resources:
    requests:
      storage: 2Gi
---
apiVersion: batch/v1
kind: CronJob
metadata:
  name: ingress-log-triage
  namespace: ops-triage
spec:
  schedule: "*/30 * * * *"
  timeZone: "Etc/UTC"
  concurrencyPolicy: Forbid
  startingDeadlineSeconds: 300
  successfulJobsHistoryLimit: 3
  failedJobsHistoryLimit: 3
  jobTemplate:
    spec:
      backoffLimit: 2
      activeDeadlineSeconds: 900
      ttlSecondsAfterFinished: 86400
      template:
        metadata:
          labels:
            app.kubernetes.io/name: ingress-log-triage
        spec:
          restartPolicy: Never
          serviceAccountName: log-triage
          nodeSelector:
            node-role.kubernetes.io/ingress: "true"
          tolerations:
            - key: node-role.kubernetes.io/ingress
              operator: Exists
              effect: NoSchedule
          securityContext:
            runAsNonRoot: true
            runAsUser: 65534
            runAsGroup: 65534
            fsGroup: 65534
            seccompProfile:
              type: RuntimeDefault
          containers:
            - name: triage
              image: debian:12-slim
              command: ["/bin/bash", "/scripts/triage.sh"]
              env:
                - name: LOG_DIR
                  value: /var/log/nginx
                - name: OUT_DIR
                  value: /reports
                - name: TOP_N
                  value: "20"
                - name: TMPDIR
                  value: /scratch
              securityContext:
                allowPrivilegeEscalation: false
                readOnlyRootFilesystem: true
                capabilities:
                  drop: ["ALL"]
              resources:
                requests:
                  cpu: 200m
                  memory: 128Mi
                limits:
                  cpu: "2"
                  memory: 512Mi
              volumeMounts:
                - name: scripts
                  mountPath: /scripts
                  readOnly: true
                - name: nginx-logs
                  mountPath: /var/log/nginx
                  readOnly: true
                - name: reports
                  mountPath: /reports
                - name: scratch
                  mountPath: /scratch
          volumes:
            - name: scripts
              configMap:
                name: log-triage-scripts
                defaultMode: 0555
            - name: nginx-logs
              hostPath:
                path: /var/log/nginx
                type: Directory
            - name: reports
              persistentVolumeClaim:
                claimName: triage-reports
            - name: scratch
              emptyDir:
                sizeLimit: 1Gi
```

Las decisiones de diseño que vale la pena defender en una revisión:

- **`memory: 512Mi` alcanza para logs arbitrariamente grandes** porque cada etapa excepto `sort` es O(1), y el directorio de volcado de `sort` es el `emptyDir` en `/scratch` vía `TMPDIR`. Sin `TMPDIR`, `sort` volcaría a `/tmp` sobre un `readOnlyRootFilesystem` y fallaría con `sort: cannot create temporary file in '/tmp': Read-only file system`.
- **`LC_ALL=C` se exporta una sola vez arriba de todo** — hace que el reporte sea reproducible entre imágenes base con distintos locales por defecto, de modo que el ancla `sha256sum` tenga sentido.
- **`concurrencyPolicy: Forbid` + `activeDeadlineSeconds`** evita la acumulación cuando una rotación hace que una ejecución sea inusualmente larga.
- **`stream()` vuelve a leer los logs para cada sección.** Es un intercambio deliberado: cinco pasadas sobre datos comprimidos cuestan CPU pero mantienen plana la memoria. Si domina la E/S, reemplazalo por una sola pasada con un fan-out `split -n r/5 --filter=...`.

Desplegar y verificar:

```
$ kubectl apply -f log-triage.yaml
namespace/ops-triage created
serviceaccount/log-triage created
configmap/log-triage-scripts created
persistentvolumeclaim/triage-reports created
cronjob.batch/ingress-log-triage created
$ kubectl -n ops-triage create job --from=cronjob/ingress-log-triage triage-manual-01
job.batch/triage-manual-01 created
$ kubectl -n ops-triage logs job/triage-manual-01 | head -n 20
report written: /reports/triage-20260826T031402Z.txt (3184 bytes)
=== ingress triage 20260826T031402Z ===

--- total requests ---
2841903

--- status code distribution ---
2705118 200
 112899 304
  20447 502
   2891 499
    548 404

--- top 20 client addresses ---
  84120 10.42.3.19
  61044 10.42.1.7
  ...
```

### 5.2 systemd: auditoría de integridad de artefactos

```ini
# /etc/systemd/system/artifact-integrity.service
[Unit]
Description=Verify checksums of deployed platform artifacts
Documentation=https://www.gnu.org/software/coreutils/manual/html_node/sha256sum-invocation.html
After=local-fs.target

[Service]
Type=oneshot
User=integrity
Group=integrity
Environment=LC_ALL=C
WorkingDirectory=/opt/platform
ExecStart=/usr/local/sbin/verify-artifacts.sh
PrivateTmp=true
ProtectSystem=strict
ProtectHome=true
NoNewPrivileges=true
ReadOnlyPaths=/opt/platform
ReadWritePaths=/var/lib/integrity
CapabilityBoundingSet=
SystemCallFilter=@system-service
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
```

```ini
# /etc/systemd/system/artifact-integrity.timer
[Unit]
Description=Hourly platform artifact integrity audit

[Timer]
OnBootSec=10min
OnUnitActiveSec=1h
RandomizedDelaySec=5min
Persistent=true
AccuracySec=1min

[Install]
WantedBy=timers.target
```

```bash
#!/usr/bin/env bash
# /usr/local/sbin/verify-artifacts.sh
set -euo pipefail
export LC_ALL=C

MANIFEST=/opt/platform/SHA256SUMS
STATE=/var/lib/integrity
mkdir -p "$STATE"

# 1. The manifest itself must be authentic, not merely present.
if ! gpg --batch --verify "${MANIFEST}.asc" "$MANIFEST" 2>/dev/null; then
  echo "FATAL: manifest signature invalid or missing" >&2
  exit 2
fi

# 2. Structural sanity before trusting it: every line must be <64 hex><2 spaces><path>.
bad=$(sed -n '/^[0-9a-f]\{64\}  ./!p' "$MANIFEST" | wc -l)
if [ "$bad" -ne 0 ]; then
  echo "FATAL: ${bad} malformed line(s) in ${MANIFEST}" >&2
  sed -n '/^[0-9a-f]\{64\}  ./!{=;p}' "$MANIFEST" >&2
  exit 2
fi
echo "manifest: $(wc -l < "$MANIFEST") entries, signature OK"

# 3. Verify. --strict turns malformed lines into failures; we already checked, belt and braces.
rc=0
sha256sum -c --strict --quiet "$MANIFEST" > "${STATE}/failures.txt" 2>&1 || rc=$?

if [ "$rc" -eq 0 ]; then
  echo "integrity: all artifacts match"
  : > "${STATE}/failures.txt"
  exit 0
fi

echo "integrity: FAILURES DETECTED" >&2
# Report the drifted paths, one per line, deduplicated and sorted.
cut -d: -f1 "${STATE}/failures.txt" | sort -u | sed 's/^/  drifted: /' >&2
exit 1
```

```
$ sudo systemctl daemon-reload
$ sudo systemctl enable --now artifact-integrity.timer
Created symlink /etc/systemd/system/timers.target.wants/artifact-integrity.timer → /etc/systemd/system/artifact-integrity.timer.
$ systemctl list-timers artifact-integrity.timer
NEXT                         LEFT       LAST                         PASSED    UNIT                      ACTIVATES
Wed 2026-08-26 04:11:37 UTC  57min left Wed 2026-08-26 03:09:12 UTC  4min ago  artifact-integrity.timer  artifact-integrity.service
$ journalctl -u artifact-integrity.service -n 5 --no-pager
Aug 26 03:09:12 node01 verify-artifacts.sh[3812]: manifest: 148 entries, signature OK
Aug 26 03:09:13 node01 verify-artifacts.sh[3812]: integrity: all artifacts match
Aug 26 03:09:13 node01 systemd[1]: artifact-integrity.service: Deactivated successfully.
```

### 5.3 CI: barrera de verificación de artefactos de release

```yaml
# .gitlab-ci.yml
stages:
  - verify

verify-release-artifacts:
  stage: verify
  image: debian:12-slim
  variables:
    LC_ALL: "C"
    UPSTREAM: "https://dl.k8s.io/release/v1.31.0/bin/linux/amd64"
  before_script:
    - apt-get update -qq && apt-get install -y -qq curl coreutils xz-utils ca-certificates
  script:
    - set -euo pipefail
    - curl -fsSLO "${UPSTREAM}/kubectl"
    - curl -fsSL  "${UPSTREAM}/kubectl.sha256" -o kubectl.upstream.sha256
    # Upstream publishes a bare digest; build a coreutils-format manifest from it.
    - printf '%s  %s\n' "$(tr -d '[:space:]' < kubectl.upstream.sha256)" kubectl > SHA256SUMS
    - cat SHA256SUMS
    - sha256sum -c --strict --status SHA256SUMS
    - echo "kubectl digest verified"
    # Fail loudly if the digest is not the one pinned in the repo.
    - cut -d' ' -f1 SHA256SUMS > got.txt
    - tr -d '[:space:]' < .pinned-kubectl-sha256 > want.txt
    - printf '\n' >> want.txt
    - diff -u want.txt got.txt || { echo "PIN MISMATCH — refusing to ship"; exit 1; }
  artifacts:
    when: always
    paths:
      - SHA256SUMS
    expire_in: 30 days
  rules:
    - if: $CI_COMMIT_TAG
```

```yaml
# .github/workflows/verify-artifacts.yml
name: verify-artifacts
on:
  push:
    tags: ['v*']
  workflow_dispatch:

jobs:
  checksums:
    runs-on: ubuntu-24.04
    env:
      LC_ALL: C
    steps:
      - uses: actions/checkout@v4

      - name: Verify bundled artifact checksums
        run: |
          set -euo pipefail
          test -s dist/SHA256SUMS || { echo "empty or missing manifest"; exit 2; }
          # Reject anything that is not exactly <64 hex><2 spaces><path>
          if sed -n '/^[0-9a-f]\{64\}  ./!p' dist/SHA256SUMS | grep -q .; then
            echo "malformed manifest lines:"
            sed -n '/^[0-9a-f]\{64\}  ./!{=;p}' dist/SHA256SUMS
            exit 2
          fi
          echo "entries: $(wc -l < dist/SHA256SUMS)"
          cd dist && sha256sum -c --strict SHA256SUMS

      - name: Detect duplicate digests (build non-determinism smell)
        run: |
          set -euo pipefail
          cut -d' ' -f1 dist/SHA256SUMS | sort | uniq -d > dupes.txt
          if [ -s dupes.txt ]; then
            echo "identical content under multiple names:"
            while read -r h; do
              sed -n "/^${h}  /p" dist/SHA256SUMS
            done < dupes.txt
          fi
```

---

## 6. Verificación y diagnóstico de fallos

### 6.1 Síntoma → causa → comando

| Síntoma | Causa probable | Diagnóstico |
|---|---|---|
| El pipeline termina con `141` | SIGPIPE porque `head`/`q` cerró el extremo de lectura | `echo "${PIPESTATUS[@]}"`; poné 141 en la lista blanca o quitá `pipefail` para ese pipeline |
| La configuración parsea pero el valor es incorrecto (`"30\r"`) | fines de línea CRLF | `cat -A file`, `od -c file \| head`; arreglar con `tr -d '\r'` o `sed -i 's/\r$//'` |
| La ruta da 404 aunque "se ve bien" | homoglifo no ASCII o NBSP | `od -A x -t x1z` — buscá `c2 a0`, `e2 80 9c` (comilla tipográfica) |
| `uniq` muestra duplicados | la entrada no está ordenada, o está ordenada con otro locale | `sort -c file`; reordená ambos lados con `LC_ALL=C` |
| `comm`/`join` no devuelve nada sensato | colación desajustada entre las dos entradas | `LC_ALL=C sort -c` en cada entrada |
| `sort -k3n` da un orden incorrecto | la clave sin cerrar se extendió hasta el fin de línea, o hay blancos iniciales | usá `-k3,3n`; agregá `-b` por clave: `-k3,3bn` |
| `cut -d' '` produce campos vacíos | las secuencias de espacios = campos vacíos | pre-normalizá: `tr -s ' '` |
| `sort` muere: `cannot create temporary file` | rootfs de solo lectura o `/tmp` lleno | fijá `TMPDIR` o `sort -T /scratch`; revisá `df -h /tmp` |
| `sort` mata el contenedor por OOM | el `-S` por defecto es demasiado grande para el límite del cgroup | fijá `sort -S 200M`; el sort de GNU no lee los límites de cgroup |
| `tail -f` se queda mudo después de medianoche | logrotate reemplazó el inodo | pasá a `tail -F`; verificá con `stat -c '%i %n' file` antes/después |
| El pipeline en vivo no emite nada y después larga una ráfaga | buffering por bloques de 4 KiB en un pipe | `stdbuf -oL`, `sed -u`, `grep --line-buffered` |
| `sed -i` falla con `Device or resource busy` | bind mount de un archivo individual (contenedor) | escribí a un temporal + `cat > target`, o montá el directorio |
| `sed -i` editó el archivo pero el demonio ve el contenido viejo | inodo reemplazado; el demonio retiene el fd viejo | recargá el servicio; `ls -i` antes/después |
| `sed -i` rompió un enlace duro / simbólico | semántica de rename | usá `--follow-symlinks`; volvé a enlazar después |
| `sha256sum -c` dice OK pero no se verificó nada | manifiesto vacío o con todas las líneas mal formadas | agregá `--strict`; verificá primero que `wc -l` > 0 |
| `split: output file suffixes exhausted` | `-a` demasiado chico para el volumen de datos | subí `-a`, o quitá `-a` y dejá que GNU lo extienda automáticamente |
| `wc -l` reporta uno menos de lo esperado | el archivo no tiene salto de línea final | `tail -c1 file \| od -c`; usá `grep -c ''` |
| `tr` corrompe los caracteres acentuados | `tr` es orientado a bytes ante entrada multibyte | usá `sed 's/x//g'` o `iconv` |
| La salida de `sort` difiere entre CI y la laptop | `LC_ALL`/`LANG` difieren | fijá `LC_ALL=C` en el entorno del job |
| Archivo enorme, `sed -n 'Np'` tarda minutos | `sed` lee hasta EOF | `sed -n 'N{p;q}'` |
| El pipeline está limitado por CPU en un solo núcleo | `sort` / `gzip` de un solo hilo | `sort --parallel`, `pigz`, `xz -T0`, o fan-out con `split --filter` |

### 6.2 Una escalera de verificación para cualquier pipeline de filtros

Ejecutá esto en orden antes de confiar en un pipeline que acabás de escribir contra datos de producción:

```bash
# 1. Does the input contain what you think it contains?
$ head -n 3 access.log | od -c | head -n 6

# 2. Is the record count what you expect, including an unterminated last line?
$ wc -l access.log ; grep -c '' access.log
2841903 access.log
2841903

# 3. Does each stage preserve cardinality as intended? Add wc -l between stages.
$ cut -d' ' -f7 access.log | wc -l
2841903
$ cut -d' ' -f7 access.log | sort -u | wc -l
14822

# 4. Is the field index actually the field you want? Verify on one line, visibly.
$ head -n 1 access.log | tr ' ' '\n' | nl | head -n 10
     1  10.42.0.7
     2  -
     3  -
     4  [26/Aug/2026:03:14:02
     5  +0000]
     6  "GET
     7  /healthz
     8  HTTP/1.1"
     9  200
    10  2

# 5. Is your sort assumption valid before uniq/comm/join?
$ cut -d' ' -f7 access.log | sort | sort -c && echo "sorted OK"
sorted OK

# 6. Are stage exit codes clean, not just the last one?
$ zcat access.log.gz | cut -d' ' -f9 | sort | uniq -c > /dev/null
$ echo "${PIPESTATUS[@]}"
0 0 0 0

# 7. Is the result reproducible? Same input, same bytes out.
$ for i in 1 2; do LC_ALL=C sort -u access.log | sha256sum; done
a1f0...  -
a1f0...  -
```

El paso 4 — `tr ' ' '\n' | nl` para enumerar los campos — vale la pena internalizarlo. Convierte "creo que el estado es el campo 9" en un hecho con un solo comando, y ha atrapado más bugs de off-by-one en índices de campo que cualquier cantidad de mirar fijo las líneas de log.

### 6.3 Diagnosticar un pipeline estancado

```
$ zcat huge.gz | sort -S 4G | uniq -c > out.txt &
[1] 4417
$ jobs -l
[1]+  4417 Running                 zcat huge.gz | sort -S 4G | uniq -c > out.txt &
$ ps -o pid,stat,wchan:20,cmd --ppid $$ --forest
  PID STAT WCHAN                CMD
 4417 S    pipe_read            zcat huge.gz
 4418 D    io_schedule          sort -S 4G
 4419 S    pipe_read            uniq -c
```

`STAT S` + `WCHAN pipe_read` en la *última* etapa significa que está hambreada — el `sort` bloqueante aguas arriba todavía no produjo nada, lo cual es esperable. `STAT D` + `io_schedule` en `sort` significa que está volcando a disco; revisá dónde y cuánto:

```
$ ls -lh /tmp/sort*
-rw------- 1 root root 1.9G Aug 26 03:21 /tmp/sortAbC123
$ df -h /tmp
Filesystem      Size  Used Avail Use% Mounted on
/dev/nvme0n1p3   50G   48G  1.4G  98% /tmp
```

Ese es tu estancamiento. `sort -T /mnt/scratch --compress-program=zstd -S 25%` lo arregla. Si la *primera* etapa está en `pipe_write` y la última está haciendo trabajo real, tenés simple contrapresión y el pipeline está sano — solo lento.

---

## 7. Práctica: trabajá esto hasta que sea un reflejo

1. Producir las 15 IP de origen más frecuentes a partir de un conjunto de logs de acceso rotados con compresión mixta, sin escribir datos sin comprimir a disco.
2. Dado `/etc/passwd`, listar los nombres de usuario de todas las cuentas con UID ≥ 1000, ordenados por UID descendente, como una única línea separada por comas.
3. Encontrar cada byte de un archivo de configuración que no sea ASCII imprimible, con su offset.
4. Dividir un log de 10 GB en exactamente 16 piezas alineadas a líneas, comprimiendo cada una con `xz` sobre la marcha y sin materializar nunca un fragmento en texto plano.
5. Verificar un artefacto descargado contra un digest upstream desnudo (sin nombre de archivo, sin separador de dos espacios) usando `sha256sum -c`.
6. Redactar todas las direcciones IPv4 y todos los valores `Authorization: Bearer …` de un log antes de entregárselo a un proveedor.
7. Reportar cuántas rutas de request *distintas* devolvieron 502, y cuál es la más frecuente, en un solo pipeline.
8. Probar que dos archivos de inventario de 5 millones de líneas contienen el mismo conjunto de nombres de host, en dos máquinas con locales por defecto distintos.

Soluciones de referencia:

```bash
# 1
for f in access.log.*; do case $f in *.gz) zcat "$f";; *.xz) xzcat "$f";; *.bz2) bzcat "$f";; *) cat "$f";; esac; done \
  | cut -d' ' -f1 | LC_ALL=C sort | uniq -c | sort -rn | head -n 15

# 2
cut -d: -f1,3 /etc/passwd | sed -n '/:[0-9]\{4,\}$/p' | sort -t: -k2,2rn | cut -d: -f1 | paste -sd,

# 3
od -A d -c -v config.env | sed -n '/[0-9]\{3\}/p'
# or, byte-exact:
tr -d '\11\12\40-\176' < config.env | od -c

# 4
split -n l/16 --filter='xz -T2 -c > $FILE.xz' --additional-suffix=.log huge.log part_

# 5
printf '%s  %s\n' "$(tr -d '[:space:]' < kubectl.sha256)" kubectl | sha256sum -c --strict -

# 6
sed -E -e 's/([0-9]{1,3}\.){3}[0-9]{1,3}/x.x.x.x/g' \
       -e 's/(Authorization: Bearer )[A-Za-z0-9._-]+/\1<REDACTED>/g' app.log

# 7
sed -n '/" 502 /p' access.log | cut -d' ' -f7 | sed 's/?.*$//' \
  | LC_ALL=C sort | uniq -c | sort -rn | { tee /dev/stderr | wc -l; } 2>/tmp/top | head -n 1 /tmp/top
# simpler, two passes:
sed -n '/" 502 /p' access.log | cut -d' ' -f7 | sed 's/?.*$//' | LC_ALL=C sort -u | wc -l
sed -n '/" 502 /p' access.log | cut -d' ' -f7 | sed 's/?.*$//' | LC_ALL=C sort | uniq -c | sort -rn | head -n 1

# 8
cut -d, -f1 inventory-a.csv | LC_ALL=C sort -u | sha256sum
cut -d, -f1 inventory-b.csv | LC_ALL=C sort -u | sha256sum
# identical digests prove identical sets; LC_ALL=C makes it locale-independent
```

---

## 8. Notas enfocadas en el examen

Más allá del encuadre de producción, el examen 101-500 evalúa estas discriminaciones específicas:

- `head -n 5` vs `head -5` — ambos funcionan en GNU, solo `-n 5` es portable según POSIX. Esperá `-n`.
- `tail -n +5` empieza **en** la línea 5; `tail -n 5` muestra las **últimas** 5. El `+` es toda la pregunta.
- `cut -c` vs `-b` vs `-f`, y el hecho de que `cut` no puede manejar delimitadores repetidos.
- `uniq` requiere entrada **ordenada** — este es el hecho más evaluado de todo el objetivo.
- `sort -u` vs `uniq`: `sort -u` no necesita entrada preordenada; `uniq` sí.
- `tr` no acepta **argumentos de archivo** — es solo stdin.
- `wc -l` cuenta saltos de línea; el orden de salida por defecto de `wc` es líneas, palabras, bytes.
- `nl` numera solo las líneas no vacías por defecto; `cat -n` numera todas.
- `od` usa por defecto **palabras en octal** (`-t o2`), lo que sorprende a todo el mundo — por eso siempre se especifica `-c`/`-t x1`.
- `zcat` maneja solo `.gz` y `.Z`; `.bz2` necesita `bzcat`, `.xz` necesita `xzcat`.
- Valores por defecto de `split`: 1000 líneas por archivo, sufijo `aa`, `ab`, …, prefijo `x`.
- `sed` sin `-n` imprime todas las líneas; `-n` más `p` es el idioma de "imprimir solo las coincidencias".
- `md5sum -c` lee un **archivo** de checksums, y el formato es `<digest><dos espacios><nombre de archivo>`.

---

## Referencias

- LPI — Objetivos del Examen 101-500 (v5.0), Tema 103.2: https://www.lpi.org/our-certifications/exam-101-objectives/
- LPI — Descripción general de la certificación LPIC-1: https://www.lpi.org/our-certifications/lpic-1-overview/
- Manual de GNU Coreutils — Salida de archivos completos (`cat`, `nl`, `od`): https://www.gnu.org/software/coreutils/manual/html_node/Output-of-entire-files.html
- Manual de GNU Coreutils — Salida de partes de archivos (`head`, `tail`, `split`): https://www.gnu.org/software/coreutils/manual/html_node/Output-of-parts-of-files.html
- Manual de GNU Coreutils — Operar sobre campos (`cut`, `paste`): https://www.gnu.org/software/coreutils/manual/html_node/Operating-on-fields.html
- Manual de GNU Coreutils — Invocación de `sort`: https://www.gnu.org/software/coreutils/manual/html_node/sort-invocation.html
- Manual de GNU Coreutils — Invocación de `uniq`: https://www.gnu.org/software/coreutils/manual/html_node/uniq-invocation.html
- Manual de GNU Coreutils — Invocación de `tr`: https://www.gnu.org/software/coreutils/manual/html_node/tr-invocation.html
- Manual de GNU Coreutils — Invocación de `wc`: https://www.gnu.org/software/coreutils/manual/html_node/wc-invocation.html
- Manual de GNU Coreutils — Invocación de `od`: https://www.gnu.org/software/coreutils/manual/html_node/od-invocation.html
- Manual de GNU Coreutils — Invocación de `split`: https://www.gnu.org/software/coreutils/manual/html_node/split-invocation.html
- Manual de GNU Coreutils — Utilidades `sha2` (`sha256sum`, `sha512sum`): https://www.gnu.org/software/coreutils/manual/html_node/sha2-utilities.html
- Manual de GNU Coreutils — Invocación de `md5sum`: https://www.gnu.org/software/coreutils/manual/html_node/md5sum-invocation.html
- Manual de GNU Coreutils — Invocación de `stdbuf`: https://www.gnu.org/software/coreutils/manual/html_node/stdbuf-invocation.html
- Manual de GNU `sed` — Ciclo de ejecución, direcciones, comandos: https://www.gnu.org/software/sed/manual/sed.html
- Manual de GNU `gzip` (`zcat`, `zless`, `zgrep`): https://www.gnu.org/software/gzip/manual/gzip.html
- `less` — Página principal y manual: https://www.greenwoodsoftware.com/less/
- XZ Utils — Página del proyecto y documentación de `xzcat`: https://tukaani.org/xz/
- bzip2 — Página del proyecto y documentación de `bzcat`: https://sourceware.org/bzip2/
- Páginas de manual de Linux — `pipe(7)`: https://man7.org/linux/man-pages/man7/pipe.7.html
- Páginas de manual de Linux — `signal(7)` (semántica de SIGPIPE): https://man7.org/linux/man-pages/man7/signal.7.html
- Páginas de manual de Linux — `locale(7)` y `strcoll(3)`: https://man7.org/linux/man-pages/man7/locale.7.html
- Páginas de manual de Linux — `inotify(7)` (comportamiento de `tail -F` y límites de watches): https://man7.org/linux/man-pages/man7/inotify.7.html
- POSIX.1-2024 Shell & Utilities — `cut`, `sort`, `uniq`, `tr`, `sed`, `wc`, `head`, `tail`, `od`, `paste`, `split`: https://pubs.opengroup.org/onlinepubs/9799919799/utilities/contents.html
- NIST FIPS 180-4 — Secure Hash Standard (SHA-256/384/512): https://csrc.nist.gov/pubs/fips/180-4/upd1/final
- Política del NIST sobre funciones hash (deprecación de MD5/SHA-1): https://csrc.nist.gov/projects/hash-functions
- Kubernetes — CronJob (`batch/v1`): https://kubernetes.io/docs/concepts/workloads/controllers/cron-jobs/
- systemd — `systemd.timer(5)`: https://www.freedesktop.org/software/systemd/man/latest/systemd.timer.html
- systemd — Directivas de sandboxing de `systemd.exec(5)`: https://www.freedesktop.org/software/systemd/man/latest/systemd.exec.html
- nginx — `log_module` / formato de log combinado: https://nginx.org/en/docs/http/ngx_http_log_module.html