# LPIC-1 · Examen 101-500 · Tema 103.7 — Buscar en archivos de texto usando expresiones regulares
## Ejercicios de laboratorio guiados (peso 4.69)

> **Alcance de este laboratorio.** El objetivo 103.7 cubre: crear expresiones regulares simples que contengan varios elementos notacionales, y usar herramientas de expresiones regulares para hacer búsquedas a través de un sistema de archivos o del contenido de un archivo. Archivos, términos y utilidades clave: `grep`, `egrep`, `fgrep`, `sed`, `regex(7)`.
> Las secciones marcadas **[fuera del examen]** son técnica de producción, no material de examen — hacelas igual, explican *por qué* las respuestas dentro del alcance del examen son las que son.

**Convenciones usadas más abajo**

- `$` precede a un comando que tenés que tipear. Las líneas sin `$` son la salida esperada.
- Toda expresión regular se escribe entre **comillas simples**. Esto no es decoración — ver el Bloque 10.
- Las salidas se produjeron con GNU grep ≥ 3.7 / GNU sed ≥ 4.8 bajo `LC_ALL=C`. En BusyBox, macOS o Toybox algunas extensiones GNU no existen; esos casos se señalan en línea.

---

## Bloque 1 — Construir el laboratorio y hacerlo determinista

La razón más común por la que dos personas obtienen salidas distintas del mismo `grep` es el **locale**. Fijalo antes que nada.

1. Creá un directorio de trabajo aislado:

```bash
$ mkdir -p ~/lab-103.7 && cd ~/lab-103.7
```

2. Fijá el locale para esta sesión de shell:

```bash
$ export LC_ALL=C
$ locale | head -3
LANG=
LC_CTYPE="C"
LC_NUMERIC="C"
```

3. Identificá tus herramientas y sus conjuntos de características:

```bash
$ grep --version | head -1
grep (GNU grep) 3.11

$ sed --version | head -1
sed (GNU sed) 4.9

$ grep -P 'x' /dev/null; echo "PCRE exit=$?"
PCRE exit=1
```

> Si el paso 3 imprime `grep: support for the -P option is not compiled into this --disable-perl-regexp binary`, tu compilación no tiene PCRE. Todos los pasos **[fuera del examen]** con `-P` no estarán disponibles; nada más en este laboratorio depende de eso.

4. Observá qué hacen `egrep` y `fgrep` en un sistema moderno:

```bash
$ echo 'abc' | egrep 'a|b'
egrep: warning: egrep is obsolescent; using grep -E
abc
```

5. Creá el corpus. Usá un delimitador de here-doc **entrecomillado** (`<<'EOF'`) para que el shell no expanda `$`, comillas invertidas ni barras invertidas:

```bash
$ cat > auth.log <<'EOF'
Aug 20 10:14:02 web01 sshd[2211]: Accepted publickey for deploy from 10.0.3.14 port 51344 ssh2
Aug 20 10:14:07 web01 sshd[2213]: Failed password for invalid user admin from 203.0.113.9 port 40122 ssh2
Aug 20 10:15:31 web01 sshd[2219]: Failed password for root from 203.0.113.9 port 40188 ssh2
Aug 20 10:15:33 web01 sshd[2219]: Failed password for root from 203.0.113.9 port 40188 ssh2
Aug 20 10:16:01 db01 CRON[2301]: pam_unix(cron:session): session opened for user root by (uid=0)
Aug 20 10:21:44 web02 sshd[3120]: Accepted password for ana from 192.168.10.55 port 33210 ssh2
Aug 20 10:22:59 web02 sshd[3140]: Failed password for invalid user test from 198.51.100.77 port 51002 ssh2
Aug 20 11:02:10 db01 sshd[4001]: Connection closed by 10.0.3.14 port 51344 [preauth]
EOF

$ cat > passwd.txt <<'EOF'
root:x:0:0:root:/root:/bin/bash
daemon:x:1:1:daemon:/usr/sbin:/usr/sbin/nologin
bin:x:2:2:bin:/bin:/usr/sbin/nologin
sync:x:4:65534:sync:/bin:/bin/sync
sshd:x:110:65534::/run/sshd:/usr/sbin/nologin
ana:x:1000:1000:Ana Diaz,,,:/home/ana:/bin/bash
deploy:x:1001:1001:Deploy Bot,,,:/home/deploy:/bin/bash
pablo:x:1002:1002::/home/pablo:/bin/sh
svc-backup:x:998:998:Backup service:/var/lib/backup:/usr/sbin/nologin
EOF

$ cat > inventory.csv <<'EOF'
host,role,env,cpu,mem_gb,ip
web01,frontend,prod,8,16,10.0.3.11
web02,frontend,prod,8,16,10.0.3.12
db01,database,prod,16,64,10.0.3.21
db02,database,staging,8,32,10.0.4.21
cache01,cache,prod,4,8,10.0.3.31
build01,ci,dev,4,8,10.0.5.10
web03,frontend,staging,4,8,10.0.4.13
EOF

$ cat > access.log <<'EOF'
10.0.3.11 - - [20/Aug/2026:10:14:02 +0000] "GET /healthz HTTP/1.1" 200 2
203.0.113.9 - - [20/Aug/2026:10:14:09 +0000] "GET /admin.php HTTP/1.1" 404 153
203.0.113.9 - - [20/Aug/2026:10:14:11 +0000] "POST /wp-login.php HTTP/1.1" 404 153
10.0.3.12 - - [20/Aug/2026:10:15:00 +0000] "GET /api/v1/users?id=42 HTTP/1.1" 200 1841
10.0.3.12 - - [20/Aug/2026:10:15:02 +0000] "GET /api/v2/users?id=42 HTTP/1.1" 200 1902
198.51.100.77 - - [20/Aug/2026:10:16:44 +0000] "GET /../../etc/passwd HTTP/1.1" 400 0
10.0.3.11 - - [20/Aug/2026:10:17:31 +0000] "GET /static/app.js HTTP/1.1" 304 0
10.0.3.21 - - [20/Aug/2026:10:19:05 +0000] "GET /metrics HTTP/1.1" 200 20481
EOF

$ cat > app.conf <<'EOF'
# Application configuration -- managed by hand
listen_addr = 0.0.0.0
listen_port = 8080
log_level   = debug
workers     = 4

[database]
host = db01.internal
port = 5432
user = appuser
password = s3cr3t-do-not-commit
sslmode = disable

[cache]
host = cache01.internal
port = 6379
ttl  = 300
EOF

$ cat > words.txt <<'EOF'
The the quick brown fox
this line has has a duplicated word
no duplicates in this one
level radar rotor stats
aa bb cc dd
EOF
```

6. Verificá que el corpus esté intacto — todos los conteos esperados posteriores dependen de estos números:

```bash
$ wc -l auth.log passwd.txt inventory.csv access.log app.conf words.txt
  8 auth.log
  9 passwd.txt
  8 inventory.csv
  8 access.log
 17 app.conf
  5 words.txt
 55 total
```

**Preguntas**

- **Q1.1** — Ejecutás `grep '[a-z]' file` en una máquina configurada con `es_ES.UTF-8` y obtenés más coincidencias que un colega ejecutando el comando idéntico. Ni el archivo ni la versión de grep difieren. ¿Cuál es el mecanismo, y qué dos variables de entorno lo controlan?
- **Q1.2** — Tu distribución incluye `egrep` y `fgrep`. ¿Cuáles son los reemplazos modernos y portables, y qué hace GNU grep ≥ 3.8 cuando invocás los nombres viejos?
- **Q1.3** — ¿Por qué se usó `<<'EOF'` en lugar de `<<EOF` en el paso 5? Nombrá un archivo de los de arriba que se habría corrompido silenciosamente en caso contrario.

---

## Bloque 2 — BRE vs ERE: la división de metacaracteres

Este es el concepto de mayor rendimiento en 103.7. `grep` (y `sed`) usan por defecto **expresiones regulares básicas (BRE)**; `grep -E` / `sed -E` seleccionan **expresiones regulares extendidas (ERE)**. El alfabeto de literales y metacaracteres es *distinto* entre ambas.

| Construcción | BRE (`grep`, `sed`) | ERE (`grep -E`, `sed -E`) |
|---|---|---|
| Cualquier carácter simple | `.` | `.` |
| Cero o más | `*` | `*` |
| Uno o más | `\+` *(ext. GNU)* | `+` |
| Cero o uno | `\?` *(ext. GNU)* | `?` |
| Intervalo | `\{n,m\}` | `{n,m}` |
| Agrupación | `\(...\)` | `(...)` |
| Alternancia | `\|` *(ext. GNU)* | `\|` → se escribe `|` |
| Retrorreferencia | `\1`…`\9` *(POSIX)* | `\1`…`\9` *(ext. GNU, no POSIX ERE)* |

1. Buscá el PID de cuatro dígitos de sshd en el log — primero en ERE, después en BRE:

```bash
$ grep -cE 'sshd\[[0-9]{4}\]' auth.log
7

$ grep -c 'sshd\[[0-9]\{4\}\]' auth.log
7
```

2. Ahora quitá el escape del corchete de apertura y observá el fallo:

```bash
$ grep -c 'sshd[0-9]\{4\}' auth.log
0
```

3. Alternancia, ERE y BRE:

```bash
$ grep -cE 'root|admin' auth.log
4

$ grep -c 'root\|admin' auth.log
4
```

4. La trampa clásica — sintaxis de alternancia usada contra el dialecto equivocado:

```bash
$ grep -c 'root|admin' auth.log
0
$ echo $?
1
```

5. Grupo opcional. Encontrá cada cuenta con una shell POSIX interactiva:

```bash
$ grep -E ':/bin/(ba)?sh$' passwd.txt
root:x:0:0:root:/root:/bin/bash
ana:x:1000:1000:Ana Diaz,,,:/home/ana:/bin/bash
deploy:x:1001:1001:Deploy Bot,,,:/home/deploy:/bin/bash
pablo:x:1002:1002::/home/pablo:/bin/sh
```

6. Lo mismo en BRE, usando las formas escapadas de GNU:

```bash
$ grep ':/bin/\(ba\)\?sh$' passwd.txt | wc -l
4
```

**Preguntas**

- **Q2.1** — En el paso 2, `sshd[0-9]\{4\}` devolvió 0 con estado de salida 1 y *sin mensaje de error*. Explicá con precisión qué pidió ese patrón, carácter por carácter, y por qué no coincidió nada.
- **Q2.2** — En el paso 4, `grep` ni dio error ni coincidió. ¿Qué entendió el motor BRE que significaba `root|admin`?
- **Q2.3** — Reescribí `grep -E '^(web|db)0[0-9],' inventory.csv` como una BRE estricta, y después predecí cuántas líneas imprime.
- **Q2.4** — ¿Cuáles dos construcciones de la columna BRE de la tabla de arriba son **extensiones GNU** en lugar de BRE POSIX, y por qué importa eso cuando escribís un script destinado a un contenedor Alpine/BusyBox?

---

## Bloque 3 — Anclas, límites de palabra y coincidencia de línea completa

Un patrón sin anclar coincide con una *subcadena*. La mayoría de los errores de `grep` en producción son patrones sin anclar que coincidieron con algo que el autor nunca consideró.

1. Anclar al inicio de línea:

```bash
$ grep -c '^Aug 20 10:1' auth.log
5
```

2. Anclar al final de línea, y ver la diferencia con la forma sin anclar:

```bash
$ grep -c 'sh' passwd.txt
5

$ grep -c 'sh$' passwd.txt
4
```

3. Identificá la línea extra que trajo la forma sin anclar:

```bash
$ grep -n 'sh' passwd.txt | grep -v 'sh$'
5:sshd:x:110:65534::/run/sshd:/usr/sbin/nologin
```

4. Límites de palabra con `-w`. `port` aparece tres veces en `app.conf`:

```bash
$ grep -n 'port' app.conf
3:listen_port = 8080
9:port = 5432
16:port = 6379

$ grep -nw 'port' app.conf
9:port = 5432
16:port = 6379
```

5. Los operadores de límite de GNU hacen lo mismo dentro del patrón, así que se combinan con la alternancia:

```bash
$ grep -nE '\b(port|host)\b' app.conf
8:host = db01.internal
9:port = 5432
15:host = cache01.internal
16:port = 6379

$ grep -n '\<port\>' app.conf
9:port = 5432
16:port = 6379
```

6. Coincidencia de línea completa con `-x`, combinada con coincidencia literal:

```bash
$ grep -nFx '[cache]' app.conf
14:[cache]
```

7. Líneas vacías y líneas de comentario — el filtro canónico de "configuración efectiva":

```bash
$ grep -c '^$' app.conf
2

$ grep -cEv '^[[:space:]]*(#|$)' app.conf
14
```

**Preguntas**

- **Q3.1** — En el paso 4, ¿por qué `-w` excluyó `listen_port` pero mantuvo `port = 5432`? ¿Qué carácter exacto detuvo la coincidencia, y cuál es la definición de grep de un "constituyente de palabra"?
- **Q3.2** — En el paso 6, ¿qué habría impreso `grep -x '[cache]' app.conf` (sin `-F`), y por qué?
- **Q3.3** — En el paso 7 se usó `^[[:space:]]*(#|$)` en lugar de `^#`. ¿Qué líneas del mundo real captura la forma más larga que `^#` pierde? ¿Por qué es necesaria la alternativa `$` si el patrón ya termina con `*`?
- **Q3.4** — Escribí un solo `grep` que imprima únicamente las líneas de `passwd.txt` donde el *campo de nombre de usuario en sí* sea exactamente `bin` (y que por lo tanto **no** imprima las líneas de `sshd` ni `daemon`, cuyos campos de home/shell contienen `/bin`).

---

## Bloque 4 — Expresiones de corchetes, clases de caracteres y locale

Una expresión de corchetes coincide con **exactamente un** carácter. Dentro de ella, casi todos los metacaracteres de regex pierden su significado especial — `.`, `*`, `+`, `(`, `|` son literales. Solo `^` (primera posición), `-` (rango) y `]` (cierre) son especiales, y cada uno tiene una regla de escape posicional.

1. Las clases de caracteres POSIX son conscientes del locale y portables; los rangos ASCII no son ni una cosa ni la otra:

```bash
$ grep -oE '[[:digit:]]{4,5}' auth.log | head -4
2211
51344
2213
40122
```

2. Expresión de corchetes negada — todo lo que no sea una coma, hasta el final de línea:

```bash
$ grep -oE '[^,]+$' inventory.csv
ip
10.0.3.11
10.0.3.12
10.0.3.21
10.0.4.21
10.0.3.31
10.0.5.10
10.0.4.13
```

3. Coincidir con un `]` literal y un `[` literal — `]` debe ir **primero**:

```bash
$ grep -o '[][]' app.conf
[
]
[
]
```

4. Coincidir con un `-` literal — debe ir primero o último, o estar escapado:

```bash
$ grep -nE '^[a-z_]+ *= *[a-z0-9.-]+$' app.conf | wc -l
12

$ grep -nE 'password = [a-z0-9-]+$' app.conf
11:password = s3cr3t-do-not-commit
```

5. El locale controla qué significa `[[:alpha:]]`. Comprobalo:

```bash
$ printf 'ñ\n' | LC_ALL=C grep -c '^[[:alpha:]]*$'
0

$ printf 'ñ\n' | LC_ALL=C.UTF-8 grep -c '^[[:alpha:]]*$'
1
```

> Si `C.UTF-8` no está disponible, usá cualquier locale UTF-8 de `locale -a`, por ejemplo `es_ES.UTF-8`.

6. Insensibilidad a mayúsculas de dos maneras — una portable, otra apoyada en `-i`:

```bash
$ grep -cE '^[Aa]ug' auth.log
8

$ grep -ci '^aug' auth.log
8
```

**Preguntas**

- **Q4.1** — `[[:digit:]]` y `[0-9]` se comportaron idénticamente en el paso 1 bajo `LC_ALL=C`. Nombrá una situación concreta donde divergen, e indicá cuál deberías escribir en código de producción.
- **Q4.2** — Explicá por qué `[][]` en el paso 3 es una expresión de corchetes bien formada que coincide con dos caracteres, mientras que `[[]]` no es lo mismo. ¿Con qué coincide realmente `[[]]`?
- **Q4.3** — ¿Qué significa `[^,]` dentro de una expresión de corchetes, y qué significa `^` *fuera* de una? Escribí un patrón que coincida con una línea que sea un único carácter que **no** sea `#`.
- **Q4.4** — En el paso 4, `[a-z0-9.-]` contiene un `.` sin escapar y un `-` al final. ¿Alguno de los dos es un metacarácter acá? Justificá ambos.
- **Q4.5** — El script de limpieza de un colega usa `grep '[A-z]'` para encontrar "letras". Bajo `LC_ALL=C`, ¿con qué caracteres ASCII que no son letras coincide también ese rango, y por qué?

---

## Bloque 5 — Cuantificadores, avidez y `-o`

Las expresiones regulares POSIX son **leftmost-longest** (la más a la izquierda, y desde ahí la más larga): la coincidencia empieza lo más temprano posible y, desde ahí, es lo más larga posible. No hay cuantificador perezoso/no-ávido en BRE ni en ERE — eso es una característica de PCRE.

1. Mirá cómo muerde la avidez, usando una línea con dos campos entrecomillados:

```bash
$ echo '"GET /a" 200 "-" "curl/8.5.0"' | grep -oE '".*"'
"GET /a" 200 "-" "curl/8.5.0"
```

2. El arreglo portable es una **expresión de corchetes negada**, no un cuantificador perezoso:

```bash
$ echo '"GET /a" 200 "-" "curl/8.5.0"' | grep -oE '"[^"]*"'
"GET /a"
"-"
"curl/8.5.0"
```

3. Aplicalo al log real para extraer las líneas de petición:

```bash
$ grep -oE '"[^"]*"' access.log | head -3
"GET /healthz HTTP/1.1"
"GET /admin.php HTTP/1.1"
"POST /wp-login.php HTTP/1.1"
```

4. Cuantificadores de intervalo — extraé los códigos de estado HTTP y ordenalos por frecuencia:

```bash
$ grep -oE '" [0-9]{3} ' access.log | tr -d '" ' | sort | uniq -c | sort -rn
      4 200
      2 404
      1 400
      1 304
```

> Los empates (`400` vs `304`) se ordenan por la comparación de última instancia de línea completa de `sort`, que `-r` invierte. Agregá `-s` o una clave `-k` si necesitás un orden estable y documentado.

5. Filtrá solo errores de cliente y de servidor:

```bash
$ grep -nE '" [45][0-9]{2} ' access.log
2:203.0.113.9 - - [20/Aug/2026:10:14:09 +0000] "GET /admin.php HTTP/1.1" 404 153
3:203.0.113.9 - - [20/Aug/2026:10:14:11 +0000] "POST /wp-login.php HTTP/1.1" 404 153
6:198.51.100.77 - - [20/Aug/2026:10:16:44 +0000] "GET /../../etc/passwd HTTP/1.1" 400 0
```

6. La regex de IP ingenua que todos escriben, y por qué está mal:

```bash
$ echo '999.1.1.1 203.0.113.9' | grep -oE '([0-9]{1,3}\.){3}[0-9]{1,3}'
999.1.1.1
203.0.113.9
```

7. La versión correcta a nivel de octeto, anclada con límites de palabra:

```bash
$ echo '999.1.1.1 203.0.113.9' | \
    grep -oE '\b((25[0-5]|2[0-4][0-9]|1[0-9]{2}|[1-9]?[0-9])\.){3}(25[0-5]|2[0-4][0-9]|1[0-9]{2}|[1-9]?[0-9])\b'
203.0.113.9
```

8. Ordená las direcciones de origen en el log de autenticación:

```bash
$ grep -oE '([0-9]{1,3}\.){3}[0-9]{1,3}' auth.log | sort | uniq -c | sort -rn
      3 203.0.113.9
      2 10.0.3.14
      1 198.51.100.77
      1 192.168.10.55
```

9. `-c` cuenta *líneas*, `-o | wc -l` cuenta *coincidencias*. No son el mismo número:

```bash
$ echo 'error error error' | grep -c 'error'
1
$ echo 'error error error' | grep -o 'error' | wc -l
3
```

**Preguntas**

- **Q5.1** — En el paso 1 el patrón `".*"` se tragó la línea entera. Recorré la regla leftmost-longest e indicá exactamente dónde empezó y dónde terminó la coincidencia.
- **Q5.2** — PCRE te dejaría escribir `".*?"`. ¿Por qué `"[^"]*"` es la *mejor* decisión de ingeniería incluso donde `grep -P` está disponible? Dá una razón de corrección y una de rendimiento.
- **Q5.3** — Sin los dos `\b` del paso 7, el patrón igual coincide con algo dentro de `999.1.1.1`. ¿Con qué exactamente, y por qué la aserción de límite lo suprime?
- **Q5.4** — Tu script de monitoreo reporta "17 errores" usando `grep -c 'ERROR' app.log`. Un postmortem muestra que ocurrieron 23 errores. Explicá la discrepancia y dá el comando corregido.
- **Q5.5** — Convertí `[0-9]{1,3}` a BRE válida, y a una forma que no use ningún cuantificador de intervalo.

---

## Bloque 6 — Búsqueda en el sistema de archivos: recursión, listas de archivos, códigos de salida

1. Construí un árbol pequeño:

```bash
$ mkdir -p site/etc site/bin site/logs
$ cp app.conf site/etc/app.conf
$ cat > site/bin/deploy.sh <<'EOF'
#!/bin/sh
API_TOKEN="tok_live_9f3ac"
curl -H "Authorization: Bearer $API_TOKEN" https://api.example.com/v1/ping
EOF
$ printf 'ok\nok\nerror: connection refused\n' > site/logs/run.log
```

2. Búsqueda recursiva con nombre de archivo y número de línea:

```bash
$ grep -rn 'password' site/
site/etc/app.conf:11:password = s3cr3t-do-not-commit
```

3. Listá solo los *archivos* que contienen una cadena con pinta de secreto, sin distinguir mayúsculas, ordenados para que sea determinista:

```bash
$ grep -rliE 'password|token|secret' site/ | sort
site/bin/deploy.sh
site/etc/app.conf
```

> Sin `sort`, el orden es el de `readdir` del sistema de archivos — nunca dependas de él en un script.

4. Invertí la lista de archivos con `-L` — archivos que **no** contienen el patrón:

```bash
$ grep -rL 'error' site/ | sort
site/bin/deploy.sh
site/etc/app.conf
```

5. Restringí la recursión con un glob de nombre de archivo:

```bash
$ grep -rn --include='*.conf' 'host' site/
site/etc/app.conf:8:host = db01.internal
site/etc/app.conf:15:host = cache01.internal

$ grep -rn --exclude-dir=logs 'ok' site/ | wc -l
0
```

6. Aprendé los tres códigos de salida — esto es lo que hace a `grep` usable en un `if`:

```bash
$ grep -q 'listen_port' app.conf; echo $?
0
$ grep -q 'listen_sock' app.conf; echo $?
1
$ grep -q 'anything' /nonexistent.conf; echo $?
grep: /nonexistent.conf: No such file or directory
2
$ grep -qs 'anything' /nonexistent.conf; echo $?
2
```

7. Usalo como deberían usarlo los scripts de producción:

```bash
$ if grep -qE '^password *=' app.conf; then
>   echo "FAIL: plaintext credential in app.conf"
> fi
FAIL: plaintext credential in app.conf
```

8. `-F` deshabilita el motor de regex por completo — el patrón pasa a ser una cadena fija:

```bash
$ echo '10x0y3z11' | grep -c '10.0.3.11'
1
$ echo '10x0y3z11' | grep -cF '10.0.3.11'
0
```

9. `-c` con múltiples archivos reporta por archivo, incluidos los ceros:

```bash
$ grep -c 'prod' inventory.csv access.log
inventory.csv:4
access.log:0
```

10. **[fuera del examen]** Traspaso seguro a `xargs` cuando los nombres de archivo pueden contener espacios o saltos de línea:

```bash
$ grep -rlZ 'password' site/ | xargs -0 -r ls -l
-rw-r--r--. 1 user user 253 Aug 26 09:12 site/etc/app.conf
```

**Preguntas**

- **Q6.1** — Indicá los tres estados de salida de grep y sus significados. ¿Por qué `grep -q pattern file && do_something` se comporta *incorrectamente* si `file` puede no existir, y qué agregás para arreglarlo?
- **Q6.2** — En el paso 8, `grep '10.0.3.11'` coincidió con `10x0y3z11`. Dá las dos maneras de hacer que esa búsqueda sea literal, e indicá cuál usarías dentro de un script que recibe la cadena desde una variable.
- **Q6.3** — ¿Cuál es la diferencia entre `-l` y `-L`? ¿Cuál es la diferencia entre `-h` y `-H`, y cuándo agrega grep prefijos de nombre de archivo sin que se lo pidas?
- **Q6.4** — Ejecutás `grep -r 'password' /etc` y obtenés `Binary file /etc/some.db matches` más una pantalla de bytes ilegibles de otro archivo. Nombrá la opción que reporta los binarios como texto, y la opción que los omite por completo.
- **Q6.5** — ¿Por qué `grep -rlZ ... | xargs -0` es preferible a `grep -rl ... | xargs`? Construí un nombre de archivo que rompa la segunda forma.

---

## Bloque 7 — Contexto, múltiples patrones y reportes

1. Líneas de contexto — antes, después y ambas:

```bash
$ grep -B1 -A1 'Connection closed' auth.log
Aug 20 10:22:59 web02 sshd[3140]: Failed password for invalid user test from 198.51.100.77 port 51002 ssh2
Aug 20 11:02:10 db01 sshd[4001]: Connection closed by 10.0.3.14 port 51344 [preauth]
```

2. Fijate en los caracteres separadores cuando `-n` se combina con contexto:

```bash
$ grep -C1 -n 'CRON' auth.log
4-Aug 20 10:15:33 web01 sshd[2219]: Failed password for root from 203.0.113.9 port 40188 ssh2
5:Aug 20 10:16:01 db01 CRON[2301]: pam_unix(cron:session): session opened for user root by (uid=0)
6-Aug 20 10:21:44 web02 sshd[3120]: Accepted password for ana from 192.168.10.55 port 33210 ssh2
```

3. Detenerse después de N coincidencias — esencial en logs de varios gigabytes:

```bash
$ grep -m2 -n 'Failed password' auth.log
2:Aug 20 10:14:07 web01 sshd[2213]: Failed password for invalid user admin from 203.0.113.9 port 40122 ssh2
3:Aug 20 10:15:31 web01 sshd[2219]: Failed password for root from 203.0.113.9 port 40188 ssh2
```

4. Múltiples patrones con `-e` (también es la forma de pasar un patrón que empieza con `-`):

```bash
$ grep -c -e 'Accepted' -e 'Connection closed' auth.log
3
```

5. Patrones desde un archivo con `-f` — un patrón por línea:

```bash
$ printf 'Accepted\nConnection closed\n' > patterns.txt
$ grep -nf patterns.txt auth.log
1:Aug 20 10:14:02 web01 sshd[2211]: Accepted publickey for deploy from 10.0.3.14 port 51344 ssh2
6:Aug 20 10:21:44 web02 sshd[3120]: Accepted password for ana from 192.168.10.55 port 33210 ssh2
8:Aug 20 11:02:10 db01 sshd[4001]: Connection closed by 10.0.3.14 port 51344 [preauth]
```

6. Invertí con `-v`, y combinalo con `-c`:

```bash
$ grep -cv -e '^#' -e '^$' app.conf
14
```

7. Encadená greps para expresar un AND lógico (grep no tiene operador AND):

```bash
$ grep 'frontend' inventory.csv | grep -c 'prod'
2
```

8. Salida con color, y la trampa que tiende:

```bash
$ grep --color=always -E 'v[12]' access.log | head -2 | cat -A | grep -o '\^\[\[[0-9;]*m' | head -3
^[[01;31m
^[[K
^[[01;31m
```

**Preguntas**

- **Q7.1** — En el paso 2, la línea 5 se imprimió con `5:` y las líneas 4 y 6 con `4-` / `6-`. ¿Qué significa cada separador, y qué tercer separador aparece entre grupos de contexto no adyacentes?
- **Q7.2** — `-m2` se detuvo después de dos coincidencias. En un log de 40 GB, ¿qué hace grep con el resto del archivo, y por qué importa más eso que el conteo de coincidencias en sí?
- **Q7.3** — Dá dos maneras distintas de buscar la cadena literal `-v` con grep, sin que grep la interprete como una opción.
- **Q7.4** — grep tiene `-e` (OR) pero no tiene AND. Dá dos formas distintas de exigir que una línea contenga *ambos*, `frontend` y `prod`: una usando un pipeline y otra usando una sola ERE.
- **Q7.5** — Un job de CI redirige `grep --color=always` a un archivo y después lo parsea, y el parseo falla. Explicá por qué, e indicá cuál de `--color=auto`, `--color=always`, `--color=never` corresponde en un script.

---

## Bloque 8 — `sed` como herramienta de búsqueda y reporte

`sed` está en el objetivo 103.7 por una razón: acepta **direcciones** que son expresiones regulares, así que puede seleccionar líneas que grep no puede (rangos, números de línea, "desde el patrón A hasta el patrón B").

1. `sed -n` + `p` es grep:

```bash
$ sed -n '/Failed password/p' auth.log | wc -l
4
```

2. Direccionamiento numérico y mixto — grep no tiene equivalente:

```bash
$ sed -n '2,4p' auth.log | wc -l
3

$ sed -n '/CRON/,$p' auth.log | wc -l
4
```

3. Rangos de regex a regex — extraé una sección de un archivo INI:

```bash
$ sed -n '/^\[database\]/,/^$/p' app.conf
[database]
host = db01.internal
port = 5432
user = appuser
password = s3cr3t-do-not-commit
sslmode = disable

```

4. Reportá números de línea con `=`:

```bash
$ sed -n '/Failed/=' auth.log
2
3
4
7

$ sed -n '$=' auth.log
8
```

5. Agrupá comandos por dirección:

```bash
$ sed -n '/^\[/{=;p}' app.conf
7
[database]
14
[cache]
```

6. Sustitución con grupos de captura — el idioma de extracción de campos. `-n` más la **bandera** `p` imprime solo las líneas donde efectivamente hubo sustitución:

```bash
$ sed -nE 's/^([^:]+):[^:]*:[0-9]+:[^:]*:[^:]*:[^:]*:(.*)$/\1 -> \2/p' passwd.txt
root -> /bin/bash
daemon -> /usr/sbin/nologin
bin -> /usr/sbin/nologin
sync -> /bin/sync
sshd -> /usr/sbin/nologin
ana -> /bin/bash
deploy -> /bin/bash
pablo -> /bin/sh
svc-backup -> /usr/sbin/nologin
```

7. `&` es la coincidencia completa; la bandera `g` y una bandera numérica seleccionan ocurrencias:

```bash
$ sed -E 's/([0-9]{1,3}\.){3}[0-9]{1,3}/<&>/g' auth.log | head -1
Aug 20 10:14:02 web01 sshd[2211]: Accepted publickey for deploy from <10.0.3.14> port 51344 ssh2

$ echo 'a a a a' | sed 's/a/X/2'
a X a a
$ echo 'a a a a' | sed 's/a/X/2g'
a X X X
```

8. Cambiá el delimitador cuando el patrón contiene barras:

```bash
$ sed -n 's|/usr/sbin/nologin|/sbin/nologin|p' passwd.txt | wc -l
4
```

9. El borrado es el inverso de `-n p`:

```bash
$ sed '/^#/d; /^$/d' app.conf | wc -l
14
```

10. Edición in situ con backup — nunca hagas esto sin `.bak` la primera vez:

```bash
$ sed -i.bak 's/^log_level\( *\)= debug/log_level\1= info/' app.conf
$ grep -n 'log_level' app.conf app.conf.bak
app.conf:4:log_level   = info
app.conf.bak:4:log_level   = debug
```

11. Transliteración con `y` (carácter por carácter, sin regex):

```bash
$ echo 'prod-web-01' | sed 'y/abcdefghijklmnopqrstuvwxyz/ABCDEFGHIJKLMNOPQRSTUVWXYZ/'
PROD-WEB-01
```

12. Restaurá el archivo para los bloques siguientes:

```bash
$ mv app.conf.bak app.conf
```

**Preguntas**

- **Q8.1** — `sed -n '/^\[database\]/,/^$/p'` imprimió 7 líneas, incluida una vacía al final. ¿Cuál es la semántica exacta de un rango `/re1/,/re2/` — en particular, se incluye la línea de cierre, y qué pasa si `re2` nunca coincide?
- **Q8.2** — En el paso 6 se usaron tanto `-n` como la bandera `p` final. Describí qué imprime el comando si sacás `-n`, y qué imprime si sacás la bandera `p`.
- **Q8.3** — `s/a/X/2` y `s/a/X/2g` dieron resultados distintos. Enunciá la regla para una bandera numérica, y para una bandera numérica combinada con `g`.
- **Q8.4** — ¿Por qué el paso 8 cambió el delimitador de `s` a `|`? Escribí la misma sustitución usando `/` como delimitador.
- **Q8.5** — `sed -i` no es una escritura in situ: describí qué le hace realmente GNU sed al inodo, y explicá qué pasa si la ruta destino es un **enlace simbólico** hacia `/etc`. ¿Qué flag cambia ese comportamiento?
- **Q8.6** — Reescribí la ERE del paso 6 como BRE (`sed -n '...p'` sin `-E`).

---

## Bloque 9 — Diagnóstico real

1. Las retrorreferencias encuentran *repetición*, algo que ninguna otra construcción puede expresar. Encontrá palabras duplicadas:

```bash
$ grep -nE '\b([a-z]+) \1\b' words.txt
2:this line has has a duplicated word

$ grep -niE '\b([a-z]+) \1\b' words.txt
1:The the quick brown fox
2:this line has has a duplicated word
```

2. Las retrorreferencias son POSIX en **BRE**, y solo una extensión GNU en ERE. Ambas formas de abajo encuentran palíndromos de cinco letras:

```bash
$ grep -oE '\b(.)(.).\2\1\b' words.txt
level
radar
rotor
stats

$ grep -o '\<\(.\)\(.\).\2\1\>' words.txt | wc -l
4
```

3. Finales de línea CRLF — el incidente "¡pero si mi regex está bien!" más común de todos:

```bash
$ printf 'listen_port = 8080\r\nlog_level = info\r\n' > windows.txt
$ grep -c 'info$' windows.txt
0
```

4. Diagnosticalo con `sed -n l`, que muestra los no imprimibles sin ambigüedad:

```bash
$ sed -n l windows.txt
listen_port = 8080\r$
log_level = info\r$
```

5. Confirmá el diagnóstico, después reparalo:

```bash
$ grep -c $'info\r$' windows.txt
1
$ sed -i 's/\r$//' windows.txt
$ grep -c 'info$' windows.txt
1
```

6. **[fuera del examen]** El lookbehind de PCRE y `\K` extraen sin grupos de captura:

```bash
$ grep -oP '(?<=port )\d+' auth.log | sort -n | head -3
33210
40122
40188

$ grep -oP 'from \K[\d.]+' auth.log | sort -u
10.0.3.14
192.168.10.55
198.51.100.77
203.0.113.9
```

7. **[fuera del examen]** Backtracking catastrófico, y por qué el motor POSIX es inmune:

```bash
$ printf 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaab\n' | timeout 5 grep -cE '^(a+)+$'
0

$ printf 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaab\n' | timeout 5 grep -cP '^(a+)+$'
```

La corrida con `-E` retorna al instante. La corrida con `-P` o bien quema 5 segundos y es terminada (`echo $?` → `124`) o aborta con `grep: exceeded PCRE's backtracking limit`. Cualquiera de los dos resultados demuestra el punto.

8. **[fuera del examen]** El locale como perilla de rendimiento en entradas grandes:

```bash
$ yes 'Aug 20 10:14:02 web01 sshd[2211]: Accepted publickey for deploy' | head -2000000 > big.log
$ time LC_ALL=en_US.UTF-8 grep -c 'sshd\[[0-9]*\]' big.log
$ time LC_ALL=C grep -c 'sshd\[[0-9]*\]' big.log
```

9. **[fuera del examen]** Muchos patrones literales a la vez — `grep -F -f` construye un único autómata de Aho–Corasick y escanea en una sola pasada:

```bash
$ grep -oE '([0-9]{1,3}\.){3}[0-9]{1,3}' auth.log | sort -u > known-ips.txt
$ grep -cFf known-ips.txt access.log
6
```

**Preguntas**

- **Q9.1** — ¿Por qué `\b([a-z]+) \1\b` no puede reescribirse sin una retrorreferencia? ¿Fuera de qué clase formal de patrones lo coloca esto?
- **Q9.2** — En el paso 3, `grep -c 'info$'` devolvió 0 en un archivo cuyos últimos caracteres visibles son `info`. Explicá a qué ancla `$` y qué carácter estaba entre `info` y el ancla.
- **Q9.3** — `sed -n l` es el diagnóstico de elección acá. Nombrá dos comandos alternativos que revelen lo mismo, e indicá qué ventaja tiene `sed -n l` sobre `cat -A`.
- **Q9.4** — El motor `-E`/`-G` de GNU grep es inmune al backtracking catastrófico; `-P` no lo es. ¿Cuál es la diferencia arquitectónica, y qué capacidad resignás a cambio de esa inmunidad?
- **Q9.5** — En el paso 6, `\K` y `(?<=...)` hacen un trabajo parecido. ¿Por qué ninguno de los dos puede reemplazarse por un simple grupo de captura al usar `grep -o`? ¿A qué herramienta que no sea grep recurrirías si solo necesitás el grupo capturado?

---

## Bloque 10 — Entrecomillado, globs y las trampas que el examen realmente pregunta

**Los globs no son expresiones regulares.** El `*` del shell significa "cualquier cadena"; el `*` de regex significa "cero o más del elemento precedente". Comparten caracteres y no comparten nada más.

| Significado | Glob del shell | Regex |
|---|---|---|
| Cualquier carácter simple | `?` | `.` |
| Cualquier cadena (incl. vacía) | `*` | `.*` |
| Un carácter de un conjunto | `[abc]` | `[abc]` |
| Cero o más `a` | — | `a*` |
| ¿Anclado por naturaleza? | sí (nombre completo) | no (subcadena) |

1. Mirá ambos motores lado a lado sobre el mismo directorio:

```bash
$ ls *.conf
app.conf
$ ls | grep '\.conf$'
app.conf
$ ls | grep '.conf$'
app.conf
```

2. Comprobá que el tercer comando del paso 1 coincidía por accidente:

```bash
$ touch xconf
$ ls | grep '.conf$'
app.conf
xconf
$ ls | grep '\.conf$'
app.conf
$ rm xconf
```

3. Entrecomillado: el shell expande antes de que grep siquiera vea el patrón:

```bash
$ echo 'HOME is $HOME' > quoting.txt
$ grep '$HOME' quoting.txt
HOME is $HOME
$ grep "$HOME" quoting.txt
$ echo $?
1
```

4. Un patrón que contiene un espacio **debe** ir entrecomillado o se convierte en dos argumentos:

```bash
$ grep -c 'Failed password' auth.log
4
$ grep -c Failed password auth.log
grep: password: No such file or directory
auth.log:4
```

5. `find` usa globs para `-name` y regex para `-regex`:

```bash
$ find site -name '*.conf'
site/etc/app.conf
$ find site -regex '.*/[a-z]*\.sh'
site/bin/deploy.sh
```

6. grep recursivo versus `find -exec` — ambos son correctos; solo uno escala:

```bash
$ grep -rl 'host' site/ | sort
site/etc/app.conf
$ find site -type f -exec grep -l 'host' {} + | sort
site/etc/app.conf
```

7. Limpieza:

```bash
$ cd ~ && rm -rf ~/lab-103.7
```

**Preguntas**

- **Q10.1** — Explicá, en términos de quién interpreta qué, por qué `ls *.conf` y `ls | grep '\.conf$'` pueden devolver resultados distintos incluso en el mismo directorio. Nombrá dos casos donde divergen.
- **Q10.2** — En el paso 3, `grep "$HOME" quoting.txt` no coincidió con nada y salió con 1. ¿Qué patrón recibió realmente grep? ¿Por qué el entrecomillado simple es la disciplina por defecto para argumentos de regex?
- **Q10.3** — Traducí el glob `data?.[ct]sv` a una ERE anclada equivalente para `grep`.
- **Q10.4** — En el paso 4, grep imprimió un error *y* un resultado, y habría salido con 2. Explicá qué pasó el shell como `argv` y qué elemento tomó grep como patrón.
- **Q10.5** — ¿Cuándo es `find ... -exec grep ... {} +` estrictamente mejor que `grep -r`? Nombrá una diferencia de comportamiento más allá de la longitud de la lista de argumentos.

---

## Respuestas

<details>
<summary><strong>Clic para expandir — respuestas completas con razonamiento</strong></summary>

### Bloque 1

**A1.1** — Las expresiones de rango como `[a-z]` se resuelven contra el **orden de colación** del locale, no contra los puntos de código ASCII. Bajo `LC_ALL=C` el orden es el valor de byte, así que `[a-z]` son exactamente las 26 letras minúsculas ASCII. Bajo un locale UTF-8 con colación estilo diccionario, el rango puede abarcar letras acentuadas y, en algunas versiones de glibc, letras mayúsculas intercaladas con minúsculas. Las variables que controlan esto son **`LC_COLLATE`** (semántica de rangos/colación) y **`LC_CTYPE`** (clasificación de caracteres, es decir qué significan `[[:alpha:]]` y la decodificación multibyte). `LC_ALL` sobrescribe a ambas; `LANG` es el respaldo para ambas. La regla de producción: `export LC_ALL=C` al comienzo de cualquier script cuyas regex deban ser reproducibles, o usar clases POSIX en lugar de rangos.

**A1.2** — `grep -E` reemplaza a `egrep`; `grep -F` reemplaza a `fgrep`. Ambos scripts envoltorio llevan décadas obsoletos y en GNU grep 3.8 (2022) se los volvió *ruidosos*: invocarlos imprime `egrep: warning: egrep is obsolescent; using grep -E` en stderr y después ejecuta el grep correcto. La advertencia va a **stderr**, así que no corrompe los datos de un pipeline — pero sí contamina los logs de CI y hará fallar cualquier test que verifique que stderr esté vacío. GNU anunció su eventual eliminación. LPI todavía lista `egrep`/`fgrep` como utilidades clave para 103.7, así que conocé tanto los nombres viejos como sus reemplazos.

**A1.3** — Con un delimitador sin entrecomillar (`<<EOF`) el shell realiza expansión de parámetros, sustitución de comandos y procesamiento de barras invertidas sobre el cuerpo del here-doc antes de escribirlo. **`site/bin/deploy.sh`** — escrito en el Bloque 6 — contiene `$API_TOKEN`, que se habría expandido a la cadena vacía, produciendo `Bearer ` y destruyendo silenciosamente el ejercicio. `app.conf` también estaría en riesgo si contuviera `$` o comillas invertidas. Entrecomillar el delimitador (`<<'EOF'`) hace que el cuerpo sea literal.

### Bloque 2

**A2.1** — `sshd[0-9]\{4\}` pide: los cuatro caracteres literales `s`,`s`,`h`,`d`; después una **expresión de corchetes** `[0-9]` que coincide con exactamente un dígito; repetida `\{4\}` veces — es decir, cuatro dígitos. Así que el patrón significa "`sshd` seguido inmediatamente de cuatro dígitos". En el log, a `sshd` le sigue un `[` literal, que no es un dígito, así que ninguna línea coincide. grep sale con 1 y no imprime nada: un patrón *sintácticamente válido pero semánticamente equivocado* produce silencio, no un error. Para coincidir con un `[` literal tenés que escaparlo (`\[`) o ponerlo en una expresión de corchetes (`[[]`). El `]` de cierre no necesita escape fuera de una expresión de corchetes, pero escaparlo (`\]`) es inocuo y simétrico.

**A2.2** — En BRE, `|` **no** es un metacarácter — es un literal ordinario. `root|admin` significa entonces la cadena literal de nueve caracteres `root|admin`, que no aparece en ninguna parte del archivo. Nada da error porque el patrón es BRE perfectamente legal. Para tener alternancia en BRE hay que usar la extensión GNU `\|`; la BRE POSIX no tiene alternancia en absoluto.

**A2.3** — Forma BRE: `grep '^\(web\|db\)0[0-9],' inventory.csv`. Imprime **6** líneas — `web01`, `web02`, `db01`, `db02`, `web03` son 5… y ninguna otra, así que recontemos: `web01`, `web02`, `db01`, `db02`, `web03` = **5** líneas. (`cache01` y `build01` no pasan el prefijo `^\(web\|db\)`; el encabezado `host,...` tampoco.) Notá que hacen falta tanto `\(...\)` como `\|`, y ambos son extensiones GNU en BRE.

**A2.4** — `\+`, `\?` y `\|` son **extensiones GNU a BRE** — la BRE POSIX define solo `.`, `*`, `[...]`, `^`, `$`, `\(...\)`, `\{n,m\}` y `\1`–`\9`. El grep de BusyBox implementa un conjunto reducido de regex y las imágenes Alpine traen BusyBox por defecto, así que un script que usa `\+` o `\|` puede funcionar en tu estación de trabajo Debian y fallar — o, peor, coincidir con los caracteres literales — dentro del contenedor. La respuesta portable es usar `grep -E` y escribir `+`, `?`, `|` sin escapar: ERE es POSIX y está implementada universalmente.

### Bloque 3

**A3.1** — El `-w` de grep exige que la coincidencia esté precedida y seguida por un **carácter que no sea constituyente de palabra (o el límite de línea)**. Un constituyente de palabra es una letra, un dígito o el guion bajo `_`. En `listen_port`, el carácter inmediatamente anterior a `port` es `_`, que *sí* es constituyente de palabra, así que la coincidencia se rechaza. En `port = 5432`, `port` está al inicio de la línea (un límite) y le sigue un espacio (no constituyente), así que se acepta. La regla del guion bajo agarra a la gente desprevenida constantemente — `-w` no va a aislar un componente de un identificador snake_case.

**A3.2** — `grep -x '[cache]'` no habría impreso **nada** (salida 1). Sin `-F`, `[cache]` es una expresión de corchetes que coincide con exactamente **un** carácter del conjunto `{c,a,h,e}`, y `-x` exige que la línea entera sea ese único carácter. La línea literal `[cache]` tiene siete caracteres, así que no hay coincidencia. Las alternativas son `grep -Fx '[cache]'`, o una regex escapada: `grep -x '\[cache\]'`.

**A3.3** — `^[[:space:]]*(#|$)` captura **comentarios indentados** (`    # note`) y **líneas compuestas solo de espacios en blanco** (una línea de espacios o tabulaciones), que `^#` y `^$` respectivamente pierden. La alternativa `$` es necesaria porque `[[:space:]]*` puede coincidir con cero caracteres y después tiene que seguir *algo*: sin la alternancia el patrón necesitaría un `#`, así que una línea en blanco no coincidiría. `(#|$)` dice "después de espacio en blanco inicial opcional, o un marcador de comentario o el final de línea".

**A3.4** — `grep '^bin:' passwd.txt`. Anclar en `^` y terminar en el separador de campo `:` restringe la coincidencia al primer campo. `grep -w 'bin'` **no** funcionaría: coincide con las apariciones de `/bin` y `/usr/sbin` en las líneas de `daemon`, `sync` y `sshd`, porque `/` no es un carácter de palabra y por lo tanto es un límite válido.

### Bloque 4

**A4.1** — Divergen en cualquier locale cuyo conjunto de dígitos sea más grande que ASCII, y más importante aún, divergen en *intención*: `[[:digit:]]` está definido por la clasificación de `LC_CTYPE`, mientras que `[0-9]` es un **rango**, resuelto por `LC_COLLATE`. En un locale con colación distinta al orden de bytes, `[0-9]` puede incluir caracteres inesperados que colacionan entre `0` y `9`, y en algunos locales/implementaciones `[[:digit:]]` también coincide con dígitos decimales no ASCII. Regla de producción: usá clases POSIX (`[[:digit:]]`, `[[:alpha:]]`, `[[:space:]]`, `[[:alnum:]]`) — expresan lo que querés decir y sobreviven a un cambio de locale. Si realmente necesitás solo ASCII, usá clases POSIX **y** fijá `LC_ALL=C`.

**A4.2** — Dentro de una expresión de corchetes, `]` pierde su significado especial si es el **primer carácter** después de `[` (o después de un `^` inicial). Así que `[][]` se analiza como: corchete de apertura, `]` literal, `[` literal, corchete de cierre — un conjunto de dos caracteres. `[[]]` se analiza como `[[]` (un conjunto que contiene solo el `[` literal) seguido de un `]` literal **fuera** de la expresión de corchetes — así que coincide con la secuencia de dos caracteres `[]`, no con "cualquiera de los dos corchetes". Esta regla posicional es la razón por la que nunca podés escapar `]` con una barra invertida dentro de una expresión de corchetes de forma portable: POSIX define la barra invertida como un *carácter ordinario* dentro de los corchetes.

**A4.3** — Dentro de una expresión de corchetes y en primera posición, `^` **niega** el conjunto: `[^,]` coincide con cualquier carácter simple que no sea una coma. Fuera de una expresión de corchetes, `^` es el **ancla de inicio de línea**. En cualquier otra posición dentro de los corchetes es un `^` literal. Una línea que sea un único carácter distinto de `#`: `grep '^[^#]$'`.

**A4.4** — Ninguno de los dos es un metacarácter acá. Dentro de una expresión de corchetes, `.` no tiene ningún significado especial — es simplemente el carácter punto literal, así que escaparlo (`[a-z0-9\.-]`) en realidad *agregaría* una barra invertida al conjunto, lo cual es un bug. El `-` es especial solo *entre* dos extremos; en **última posición** (como acá) solo puede ser literal, así que `[a-z0-9.-]` es el conjunto {letras minúsculas, dígitos, `.`, `-`}. Un `-` en primera posición es literal igualmente.

**A4.5** — `[A-z]` abarca desde ASCII 65 (`A`) hasta 122 (`z`), lo que incluye los seis caracteres de puntuación entre `Z` (90) y `a` (97): **`[`, `\`, `]`, `^`, `_`, `` ` ``**. Es un bug clásico de rango mal calculado. Las formas correctas son `[A-Za-z]` o, mejor, `[[:alpha:]]`.

### Bloque 5

**A5.1** — Leftmost-longest: el motor encuentra la posición más temprana en la que *alguna* coincidencia es posible — el offset 0, la primera `"`. Desde ese inicio toma la coincidencia **más larga**, así que `.*` consume todo lo que puede mientras todavía permita una `"` final — la última `"` de la línea, al final de `curl/8.5.0"`. La coincidencia por lo tanto abarca desde el offset 0 hasta el final de línea. `-o` imprime exactamente ese tramo. Notá que POSIX especifica leftmost-longest para la coincidencia *global*; no es el "backtracking ávido" de PCRE, pero el efecto visible acá es el mismo.

**A5.2** — **Corrección:** `[^"]*` es una restricción dura — la coincidencia físicamente no puede cruzar una `"`. `.*?` es solo una *preferencia*; al hacer backtracking, un cuantificador perezoso se expandirá gustosamente más allá de una comilla si eso hace que el patrón global tenga éxito, produciendo coincidencias sorprendentes con entradas malformadas. **Rendimiento:** `"[^"]*"` compila a un autómata determinista sin backtracking (tiempo lineal, y funciona en `-E`/`-G` en todo grep POSIX). `".*?"` requiere el motor de backtracking de PCRE, no está disponible en `-E`, y no es portable a BusyBox ni al grep de macOS.

**A5.3** — Sin los límites, el motor puede empezar en el offset 1 de `999.1.1.1`: `[1-9]?[0-9]` coincide con `99`, después `\.` coincide con `.`, después `1`, `.`, `1`, `.`, `1` — produciendo la coincidencia espuria `99.1.1.1`. `\b` exige una transición palabra/no-palabra en los bordes de la coincidencia; entre el primer y el segundo `9` ambos caracteres son constituyentes de palabra, así que ahí no existe ningún límite y la posición de inicio se rechaza. En el offset 0 el patrón genuinamente falla (`999` no puede ser un octeto bajo esta alternancia), así que el token completo se omite.

**A5.4** — `grep -c` cuenta **líneas coincidentes**, no coincidencias. Seis de los errores compartían línea con otro error (por ejemplo, una línea de stack trace que contiene `ERROR` dos veces, o varios errores concatenados). Corregido: `grep -o 'ERROR' app.log | wc -l`, que imprime una línea por coincidencia. Si el patrón puede coincidir con la cadena vacía, preferí `grep -o` con un patrón que no pueda.

**A5.5** — BRE: `[0-9]\{1,3\}`. Sin ningún cuantificador de intervalo: `[0-9][0-9]\{0,1\}[0-9]\{0,1\}` sigue usando intervalos, así que la forma libre de intervalos es `[0-9][0-9]\?[0-9]\?` en BRE de GNU, o en BRE POSIX estricta sin extensiones: `[0-9]\([0-9]\([0-9]\)*\)*` está mal (no acotado) — la forma POSIX correcta libre de intervalos es la alternancia `[0-9][0-9][0-9]\|[0-9][0-9]\|[0-9]` con la alternativa más larga primero, o en ERE `[0-9][0-9][0-9]|[0-9][0-9]|[0-9]`. Precisamente para esto existen los cuantificadores de intervalo.

### Bloque 6

**A6.1** — `0` = al menos una línea seleccionada; `1` = ninguna línea seleccionada, sin error; `2` = ocurrió un error (archivo ilegible, regex inválida, archivo faltante). `grep -q p f && do_something` está mal para un archivo faltante solo si asumiste que "distinto de cero significa no encontrado" — el peligro real es la forma inversa `grep -q p f || alert`, que dispara la alerta tanto por "no encontrado" (1) como por "archivo faltante" (2), enmascarando una falla de infraestructura genuina. Distinguí explícitamente:
```bash
grep -q 'p' f; rc=$?
case $rc in 0) found;; 1) not_found;; *) echo "grep error" >&2; exit 2;; esac
```
`-s` suprime el *mensaje* para archivos inexistentes o ilegibles pero **no** cambia el estado de salida — un error de concepto muy común.

**A6.2** — (a) `grep -F '10.0.3.11'` — deshabilita el motor de regex por completo. (b) `grep '10\.0\.3\.11'` — escapar cada metacarácter. Para una cadena que viene de una **variable**, usá siempre `-F` (idealmente `grep -F -- "$needle"`): escapar a mano una variable arbitraria es un bug de inyección esperando ocurrir, porque no podés saber qué metacaracteres contiene.

**A6.3** — `-l` imprime el nombre de cada archivo con al menos una coincidencia y deja de leer ese archivo; `-L` imprime los nombres de los archivos **sin** coincidencia. `-H` fuerza el prefijo `filename:`, `-h` lo suprime. grep agrega el prefijo automáticamente siempre que recibe más de un operando de archivo, o cuando se usa `-r`/`-R` — incluso cuando la recursión encuentra un solo archivo, razón por la cual los scripts que parsean la salida de `grep -r` no deben asumir que el prefijo está ausente.

**A6.4** — `--binary-files=text` (o su sinónimo corto `-a`) trata el contenido binario como texto e imprime las líneas coincidentes. `-I` (i mayúscula) es la abreviatura de `--binary-files=without-match` y omite los binarios por completo — la opción correcta para un escaneo de secretos en un árbol de fuentes. Notá que grep decide qué es "binario" buscando bytes NUL o codificación inválida en el primer búfer, así que un archivo de texto UTF-16 se trata como binario.

**A6.5** — `-Z` (con `-l`) termina cada nombre de archivo con un byte NUL en lugar de un salto de línea, y `xargs -0` divide por NUL. Como NUL es el único byte que no puede aparecer en un nombre de archivo POSIX, este es el único pipeline sin pérdidas. Entrada que rompe la segunda forma: `touch $'site/etc/my\nfile.conf'` — el salto de línea embebido hace que `xargs` a secas vea dos nombres de archivo, `site/etc/my` y `file.conf`, ninguno de los cuales existe. Los nombres con espacios o comillas también la rompen. Agregá `-r` (`--no-run-if-empty`) para que `xargs` no ejecute el comando con cero argumentos cuando grep no encuentra nada.

### Bloque 7

**A7.1** — `:` separa el número de línea (o el nombre de archivo) de una línea que **coincidió**; `-` lo separa de una línea de **contexto** aportada por `-A`/`-B`/`-C`. Cuando dos grupos de coincidencias están separados por líneas que no se imprimieron, grep emite una línea separadora de grupo formada por `--`. Ese `--` es la razón por la que la salida de `grep -C` no puede alimentarse ingenuamente a otro parser; `--no-group-separator` lo suprime.

**A7.2** — Con `-m2`, grep deja de leer apenas se emite la segunda coincidencia (después de completar cualquier contexto `-A` final), así que los ~40 GB restantes nunca se leen del disco. El punto es **E/S y tiempo**, no el volumen de salida: `grep 'x' huge.log | head -2` igual lee el archivo entero hasta que llega el SIGPIPE, y en un sistema de archivos lento o de red esa es la diferencia entre milisegundos y minutos. `-m` también cambia útilmente la semántica del estado de salida: sale con 0 de inmediato.

**A7.3** — (a) `grep -e '-v' file` — `-e` introduce explícitamente un patrón. (b) `grep -- '-v' file` — `--` termina el análisis de opciones. Una tercera, si el patrón es literal: `grep -F -e '-v' file`.

**A7.4** — Pipeline: `grep 'frontend' inventory.csv | grep 'prod'`. Una sola ERE en forma independiente del orden: `grep -E 'frontend.*prod|prod.*frontend' inventory.csv`. Si el orden en la línea está garantizado (como en este CSV), `grep -E 'frontend,prod'` alcanza. El pipeline es más claro y más barato para dos términos; la ERE importa cuando necesitás una sola pasada sobre un archivo enorme. (El lookahead de PCRE — `grep -P '(?=.*frontend)(?=.*prod)'` — es la versión concisa, pero no es portable.)

**A7.5** — `--color=always` inyecta secuencias de escape ANSI (`ESC[01;31m`, `ESC[K`, `ESC[m`) dentro del *flujo de datos*, así que el parser aguas abajo ve `\033[01;31mERROR\033[m` en lugar de `ERROR` y sus propios patrones no coinciden. `--color=auto` — el valor usado por el `alias grep='grep --color=auto'` de la distro — colorea solo cuando stdout es una terminal, y por eso el problema es invisible de forma interactiva y aparece solo en CI. En un script, pasá `--color=never` explícitamente o, mejor, evitá heredar el alias llamando a `command grep` o `/usr/bin/grep`. Usá `--color=always` solo cuando deliberadamente canalizás a un paginador con `less -R`.

### Bloque 8

**A8.1** — `/re1/,/re2/` selecciona desde la primera línea que coincide con `re1` **hasta** la siguiente línea que coincide con `re2`, inclusive en ambos extremos. Crucialmente, la búsqueda de `re2` empieza en la línea *posterior* a la coincidencia de `re1`, así que un rango cuyas dos regex coincidan con la misma línea igual abarca al menos dos líneas. Si `re2` nunca coincide, el rango corre hasta el **final del archivo** — un comportamiento silencioso y peligroso cuando el delimitador de cierre es opcional (una sección INI al final de un archivo sin línea en blanco final se traga todo). La línea vacía final en la salida es la línea `/^$/` en sí, incluida por la regla de inclusividad.

**A8.2** — Sin `-n`: la impresión automática de sed vuelve a estar activa, así que cada línea se imprime una vez por el auto-print *y* una segunda vez por la bandera `p` si hubo sustitución — las líneas coincidentes aparecen dos veces, las no coincidentes una. Sin la bandera `p` (pero con `-n`): sed no imprime **nada en absoluto**, porque `-n` deshabilita el auto-print y ningún comando solicita salida. El par `-n` + `s///p` es el idioma de sed para "imprimir solo las líneas transformadas"; es el análogo directo de `grep -o`.

**A8.3** — Una bandera numérica `N` reemplaza **solo la N-ésima** ocurrencia de la línea, dejando intactas todas las demás. `Ng` reemplaza la N-ésima ocurrencia **y todas las posteriores**. `g` a secas reemplaza todas. La forma combinada `Ng` es una extensión GNU; la bandera numérica sola es POSIX.

**A8.4** — Tanto el patrón como el reemplazo contienen `/`, que es el delimitador por defecto; usar `/` obligaría a escapar cada uno de ellos. `sed` permite que cualquier carácter siga a `s` como delimitador, así que `|` (o `#`, `,`, `%`) elimina el escapado por completo. Con `/`: `sed -n 's/\/usr\/sbin\/nologin/\/sbin\/nologin/p' passwd.txt` — el problema de los "palillos inclinados". Notá que cuando cambiás el delimitador, ese carácter debe entonces escaparse si aparece en el patrón.

**A8.5** — GNU `sed -i` escribe el resultado en un **archivo temporal en el mismo directorio** y después hace `rename(2)` sobre el destino. El inodo cambia: el inodo original se desvincula, así que cualquier descriptor de archivo abierto, enlace duro o proceso que retenga el archivo viejo conserva el contenido *viejo*, y la propiedad y permisos se rederivan en lugar de preservarse. Si el destino es un **enlace simbólico**, el rename reemplaza al enlace simbólico mismo por un archivo regular — `/etc/resolv.conf` → `/run/systemd/resolve/stub-resolv.conf` es la manera canónica en que la gente destruye un sistema con `sed -i`. `--follow-symlinks` hace que GNU sed resuelva el enlace y edite el destino real. Usá siempre `sed -i.bak` la primera vez, y preferí `sed ... > tmp && mv tmp file` cuando necesites controlar la propiedad.

**A8.6** — `sed -n 's/^\([^:]*\):[^:]*:[0-9]*:[^:]*:[^:]*:[^:]*:\(.*\)$/\1 -> \2/p' passwd.txt`. Cada `(` `)` se vuelve `\(` `\)`; `+` se vuelve `*` con un elemento obligatorio precedente, o usá el `\+` de GNU. Las retrorreferencias `\1`/`\2` se escriben idénticamente en ambos dialectos — son POSIX en BRE y una extensión GNU en ERE.

### Bloque 9

**A9.1** — `\1` exige que la segunda aparición sea **la misma cadena** que capturó el grupo, lo que requiere que el motor recuerde una entrada no acotada. Una expresión regular pura (en el sentido formal de autómata finito) tiene solo memoria finita, así que el lenguaje "una palabra, un espacio, y después esa misma palabra" no es regular — es el clásico lenguaje `ww`, demostrablemente fuera de la clase regular (lema del bombeo). Las retrorreferencias por lo tanto empujan al lenguaje del patrón más allá de lo regular, que es exactamente por qué fuerzan una implementación con backtracking y por qué POSIX las coloca en BRE, donde la implementación ya estaba obligada a hacer backtracking. También es por eso que la ruta rápida de DFA de grep se deshabilita para patrones que las contengan.

**A9.2** — `$` ancla al **final de la línea lógica**, es decir, la posición inmediatamente anterior al `\n` que grep eliminó. El archivo tiene finales de línea DOS, así que la secuencia de bytes es `info` `\r` `\n`; grep elimina solo el `\n`, dejando un retorno de carro (0x0D) como último carácter de la línea. `info$` falla entonces porque a `info` le sigue `\r`, no el final de línea. `$'info\r$'` funciona porque el entrecomillado ANSI-C inserta un CR real en el patrón.

**A9.3** — `cat -A` (o `cat -v -E -T`) muestra `^M$` al final de cada línea; `od -c file | head` muestra los pares de bytes `\r \n` crudos; `file windows.txt` reporta `ASCII text, with CRLF line terminators`. `sed -n l` tiene la ventaja de usar escapes al estilo regex (`\r`, `\t`, `\\`) en lugar de la notación de acento circunflejo, y de ajustar las líneas largas a un ancho configurable (`sed -n 'l 0'` desactiva el ajuste) — así que la salida se lee directamente como algo que podrías pegar de vuelta en un patrón. `file` es la verificación inicial más rápida.

**A9.4** — El motor POSIX de GNU grep compila el patrón a una **simulación DFA/NFA** que sigue un *conjunto* de estados activos en paralelo y nunca hace backtracking, dando un peor caso de O(n·m) y sin dependencia de patologías de la entrada. PCRE usa un motor de **backtracking recursivo** que explora las alternativas una por vez, lo que con `^(a+)+$` contra `aaaa…b` explora una cantidad exponencial de particiones antes de fallar. Las capacidades que resignás a cambio de la inmunidad del DFA son exactamente las no regulares: lookahead/lookbehind, cuantificadores perezosos, grupos atómicos, `\K`, recursión y retrorreferencias (eficientes). Esta es una compensación de ingeniería genuina, no un defecto: elegí `-E` para entradas no confiables, `-P` solo para patrones confiables sobre datos confiables, y considerá herramientas basadas en RE2 (`ripgrep`) cuando querés las dos cosas.

**A9.5** — `grep -o` imprime **la coincidencia completa**, no un grupo de captura — grep no tiene `--only-group`. Así que un grupo de captura no puede acotar la salida; tenés que sacar el texto no deseado fuera de la coincidencia en sí, que es precisamente lo que hacen un lookbehind de ancho cero `(?<=from )` o un reinicio de coincidencia `\K`. Si necesitás grupos de captura, usá `sed -nE 's/.../\1/p`' (portable, POSIX, dentro del objetivo del examen), o `perl -nle 'print $1 if /from (\S+)/'` para extracción arbitraria de grupos. Para datos estructurados, usá la herramienta consciente del formato (`awk`, `jq`, `yq`) en vez de una regex.

### Bloque 10

**A10.1** — `ls *.conf`: el **shell** expande el glob contra las entradas del directorio y pasa los nombres de archivo resultantes a `ls`, que nunca ve un patrón. `ls | grep '\.conf$'`: **`ls`** lista todo, y **grep** filtra su stdout como texto. Divergencias: (1) **Archivos ocultos** — un glob no coincide con un `.` inicial salvo que `dotglob` esté activo, así que `.hidden.conf` es invisible para `*.conf` pero sí es listado y coincidido por la forma con grep. (2) **Sin coincidencias** — si no hay archivo coincidente, bash deja `*.conf` literal y `ls` da error con `No such file or directory` (salvo que `nullglob`/`failglob` estén activos), mientras que la forma con grep simplemente sale con 1 en silencio. (3) **Nombres de archivo con saltos de línea** rompen la forma con grep, que es una de varias razones por las que `ls | grep` no debe manejar scripts — usá `find` o un glob.

**A10.2** — Las comillas dobles permiten la expansión de parámetros, así que el shell expandió `$HOME` y grep recibió el patrón `/home/dalmine` (o el que sea tu home). Esa cadena no aparece en `quoting.txt`, de ahí que no haya coincidencia y salga con 1. Las comillas simples suprimen toda forma de expansión del shell, así que grep recibe la regex byte por byte. Esto importa mucho más allá de `$`: `*`, `?`, `[`, `]`, `\`, las comillas invertidas y los espacios son todos significativos para el shell y todos significativos para regex, y las dos interpretaciones difieren. **Disciplina: entrecomillá con comillas simples cada regex; si tenés que interpolar una variable, interpolala en un patrón `-F`, no en una regex.**

**A10.3** — `grep -E '^data.\.[ct]sv$'`. Correspondencia: glob `?` → regex `.`; glob `.` → regex `\.`; glob `[ct]` → regex `[ct]` (idéntico); y como un glob está implícitamente anclado al nombre de archivo completo, hay que agregar `^` y `$` explícitamente — una regex es por defecto una búsqueda de subcadena. (`grep -Ex 'data.\.[ct]sv'` es equivalente.)

**A10.4** — El shell hizo división en palabras sobre el argumento sin entrecomillar, así que el `argv` de grep fue `["grep", "-c", "Failed", "password", "auth.log"]`. grep toma el primer operando que no es una opción como el **patrón** — `Failed` — y trata todo lo que sigue como operandos de archivo: `password` (inexistente → error a stderr, estado de salida 2 pendiente) y `auth.log` (legible → `auth.log:4`, y el prefijo de nombre de archivo aparece porque ahora hay más de un operando de archivo). El estado de salida final es **2**, porque el error domina. La lección: un patrón multipalabra sin entrecomillar cambia silenciosamente el significado de toda la línea de comandos.

**A10.5** — `find ... -exec grep ... {} +` es estrictamente mejor cuando necesitás los predicados de `find`: `-type f` (omitir dispositivos, FIFOs y sockets en los que `grep -r` se bloqueará gustosamente), `-mtime`, `-size`, `-user`, `-prune` para exclusiones de directorios complejas, o `-xdev` para quedarse en un solo sistema de archivos. Diferencias de comportamiento más allá de la longitud de argumentos: (1) `grep -r` sigue los enlaces simbólicos dados en la línea de comandos pero no los encontrados durante el recorrido, mientras que `-R` los sigue todos — `find` te da control explícito con `-L`/`-P`; (2) con `+`, `find` puede invocar grep **múltiples veces**, así que los límites de `-m`, los totales de `-c` y los estados de salida aplican por invocación, y los separadores de grupo `--` se reinician; (3) `grep -r` reporta sus propios errores de recorrido, mientras que `find` reporta los suyos, lo que cambia qué aparece en stderr y en qué orden. Para un "buscar en este árbol" puro, `grep -r --include=` es más simple y más rápido; para "buscar en archivos que cumplan estos atributos", usá `find`.

</details>

---

## Autoverificación del objetivo

Antes de seguir, deberías poder hacer cada una de estas cosas sin ayuda:

- [ ] Decir de memoria cuáles de `+ ? { } ( ) |` requieren barra invertida en BRE y cuáles no en ERE.
- [ ] Explicar por qué `grep '10.0.3.11'` no es una búsqueda de una dirección IP.
- [ ] Anclar un patrón al inicio de línea, al final de línea, a la línea completa y a la palabra completa — y decir por qué `-w` trata `_` como parte de una palabra.
- [ ] Escribir una expresión de corchetes que contenga un `]` literal, un `-` literal y un `^` literal.
- [ ] Predecir la salida de `grep -c` versus `grep -o | wc -l` en una línea con coincidencias repetidas.
- [ ] Recitar los tres estados de salida de grep y usarlos en un `if`.
- [ ] Usar `sed -n` con una dirección numérica, una dirección de regex y un rango `/re1/,/re2/`.
- [ ] Extraer un campo con `sed -nE 's/.../\1/p'`.
- [ ] Diagnosticar un ancla `$` fallida causada por finales de línea CRLF.
- [ ] Explicar la diferencia entre un glob del shell y una expresión regular, con un ejemplo de cada divergencia.

## Fuentes oficiales

- LPI — Objetivos del Examen 101-500 (tema 103.7): <https://www.lpi.org/our-certifications/exam-101-objectives/>
- Manual de GNU grep (expresiones regulares, opciones, estado de salida): <https://www.gnu.org/software/grep/manual/grep.html>
- Manual de GNU sed (direcciones, comando `s`, `-i`, comando `l`): <https://www.gnu.org/software/sed/manual/sed.html>
- `regex(7)` — expresiones regulares POSIX en Linux: <https://man7.org/linux/man-pages/man7/regex.7.html>
- `grep(1)`: <https://man7.org/linux/man-pages/man1/grep.1.html>
- `glob(7)` — coincidencia de patrones del shell, para la distinción glob vs regex: <https://man7.org/linux/man-pages/man7/glob.7.html>
- POSIX.1-2017, Base Definitions Capítulo 9 — Expresiones Regulares (definiciones normativas de BRE/ERE): <https://pubs.opengroup.org/onlinepubs/9699919799/basedefs/V1_chap09.html>
- Sintaxis de patrones PCRE2 (para las secciones con `-P`): <https://www.pcre.org/current/doc/html/pcre2syntax.html>