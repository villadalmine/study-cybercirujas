# 103.7 — Búsqueda en archivos de texto mediante expresiones regulares

**Certificación:** LPIC-1 (LPI 101-500 + 102-500), versión 5.0
**Examen:** 101-500 · **Tema:** 103 (Comandos GNU y Unix) · **Objetivo:** 103.7
**Peso (normalizado por la plataforma):** 4.69
**Áreas de conocimiento clave:** crear expresiones regulares que contengan varios elementos notacionales; comprender la diferencia entre expresiones regulares básicas y extendidas; usar herramientas de expresiones regulares para buscar en un sistema de archivos o en el contenido de un archivo.
**Términos y utilidades:** `grep`, `egrep`, `fgrep`, `sed`, `regex(7)`

---

## 1. Motivación: las expresiones regulares son un plano de control de producción, no una comodidad para editar texto

El examen plantea el 103.7 como «encontrar texto en archivos». Ese planteo tiene 30 años y es la razón por la cual los ingenieros invierten poco en este objetivo y después reciben una llamada de guardia por él. En una plataforma moderna, una expresión regular es **configuración ejecutable en el camino crítico de cada decisión de observabilidad y de enrutamiento que tomás**. Considerá dónde se evalúa una regex en una plataforma Kubernetes típica:

| Capa | Componente | Qué decide la regex | Frecuencia de evaluación | Radio de impacto cuando está mal |
|---|---|---|---|---|
| Recolección de logs | Parser de Fluent Bit / Vector / Promtail | Si una línea de log se convierte en campos estructurados o se descarta como no parseable | Una vez por línea de log — 10⁴–10⁶ líneas/s por nodo | Pérdida silenciosa de logs; saturación de CPU del DaemonSet; contrapresión a nivel de nodo |
| Consulta de logs | Loki `|~`, LogQL `line_format` | Qué líneas responden a una consulta de incidente | Por consulta, sobre TB de chunks | Conclusión errónea del incidente; timeouts de consulta |
| Descubrimiento de métricas | `relabel_configs.regex` de Prometheus | Qué targets se scrapean y cómo se construyen las labels | Una vez por refresco de SD, por target | Capas enteras de targets dejan de scrapearse en silencio — los dashboards quedan en blanco, las alertas nunca disparan |
| Ingesta de métricas | `metric_relabel_configs` | Qué series se conservan | Por scrape, por serie | Explosión de cardinalidad → OOM de la TSDB |
| Enrutamiento de alertas | `matchers` de Alertmanager (`=~`) | Qué equipo recibe la llamada | Por alerta | Llamadas enrutadas al on-call equivocado, o a nadie |
| Ingress | `location ~` de NGINX, `safe_regex` de Envoy | Qué backend sirve una petición | Por petición | Enrutamiento incorrecto del tráfico; rechazos de RE2 por tamaño de programa al cargar la configuración |
| CI/CD | Compuertas de política basadas en `grep` | Si un commit se mergea | Por pipeline | Secretos mergeados a `main` |
| Autenticación/auditoría | `auditd`, filtros de `rsyslog`, coincidencia de comandos en `sudoers` | Qué se registra, qué se permite | Por syscall / por mensaje | Puntos ciegos de auditoría |

Cada uno de estos es un *motor de regex distinto, con sintaxis distinta y semántica de falla distinta*, y quien escribe la configuración normalmente la valida con `grep` en una laptop. Ese desajuste es el problema arquitectónico del que este objetivo realmente te protege.

### 1.1 Modo de falla #1 — el pipeline de logs que se comió un nodo (backtracking catastrófico)

Un equipo agrega un parser para un servicio nuevo. La regex tiene un aspecto plausible:

```
^(?<ts>\S+)\s+(?<level>\w+)\s+(\[(?<thread>[^\]]*)\]\s*)*(?<msg>.*)$
```

El `( ... )*` anidado alrededor de un grupo que a su vez puede coincidir con la cadena vacía convierte una línea *que no coincide* en trabajo exponencial en cualquier motor con backtracking. Fluent Bit usa **Onigmo** (un motor con backtracking). Las líneas de log que *sí* coinciden cuestan microsegundos; el 0,1 % que no coincide — una línea truncada, la continuación de un stack trace — cuesta segundos cada una. El pod del DaemonSet clava un core, el búfer de entrada se llena, se alcanza `Mem_Buf_Limit` y Fluent Bit **descarta** registros con `[warn] [input] emitter.4 paused`. Perdés exactamente los logs del incidente que produjo las líneas mal formadas.

`grep -E` habría determinado al instante que esa misma regex no coincide, porque el matcher principal de GNU `grep` es un **DFA** — no puede hacer backtracking. Probar con el motor equivocado no probó nada.

### 1.2 Modo de falla #2 — el desajuste de anclaje

```yaml
- source_labels: [__meta_kubernetes_pod_label_app]
  regex: api          # intent: "keep anything whose app label contains api"
  action: keep
```

En `grep`, `api` coincide con `payments-api`. En Prometheus, **`regex` está implícitamente anclada en ambos extremos** (`^(?:api)$`), así que `payments-api` se descarta y la capa deja de scrapearse. No hay error, no hay advertencia, no hay métrica. Simplemente `up` deja de existir para esos targets, y las alertas basadas en `absent()` suelen ser lo único que lo detecta — si alguien las escribió.

La trampa inversa existe en Alertmanager (`=~` está anclado) y *no* en Loki (`|~` no está anclado). El mismo archivo YAML, tres reglas de anclaje.

### 1.3 Modo de falla #3 — el locale

```bash
$ grep -c '[a-z]' names.txt      # LANG=en_US.UTF-8
```
POSIX declara **no especificado** el comportamiento de los rangos fuera del locale C; glibc los ordena por *collation*, así que `[a-z]` puede coincidir con caracteres que nunca pretendiste, y la decodificación multibyte hace que la misma búsqueda sea entre 3 y 10 veces más lenta. La forma portable, rápida y correcta es `[[:lower:]]` y, para el escaneo de logs orientado a bytes, `LC_ALL=C`.

### 1.4 La regla de ingeniería que enseña este objetivo

> Escribí la regex más pequeña que no pueda hacer backtracking, en la sintaxis del motor que realmente la va a ejecutar, y validala contra un corpus de referencia con entradas que coinciden y entradas que **no coinciden** — en ese motor.

Todo lo que sigue es la mecánica necesaria para lograrlo.

---

## 2. El modelo de las expresiones regulares

### 2.1 Dos dialectos POSIX, y por qué son incompatibles en ambas direcciones

POSIX define **BRE** (Basic Regular Expressions, el modo por defecto de `grep`/`sed`) y **ERE** (Extended, `grep -E`/`sed -E`/`awk`). No es que «ERE sea BRE más funciones»: varios caracteres son *especiales en uno y literales en el otro*, lo que significa que un patrón puede ser válido en ambos en silencio y significar cosas distintas.

| Construcción | BRE | ERE | Notas |
|---|---|---|---|
| Cualquier carácter | `.` | `.` | Nunca coincide con NUL en `grep` salvo con `-z`; coincide con el salto de línea solo donde la herramienta presenta saltos de línea (`sed -z`, `grep -z`) |
| Expresión entre corchetes | `[abc]`, `[^abc]`, `[a-z]` | igual | `]` al principio es literal (`[]abc]`), `-` al final es literal (`[abc-]`), `^` al principio niega |
| Clase de caracteres | `[[:digit:]]` | `[[:digit:]]` | Solo válida **dentro** de corchetes |
| Anclas | `^` `$` | `^` `$` | **BRE:** especial solo al inicio/final de la RE o de una subexpresión; literal en cualquier otro lugar. **ERE:** siempre especial |
| Cero o más | `*` | `*` | BRE: literal cuando es el primer carácter de una RE o subexpresión |
| Uno o más | `\+` *(ext. GNU)* | `+` | Un `+` simple en BRE es un signo más literal |
| Cero o uno | `\?` *(ext. GNU)* | `?` | Un `?` simple en BRE es un signo de interrogación literal |
| Intervalo | `\{n,m\}` | `{n,m}` | Techo portable `RE_DUP_MAX` = 255 |
| Agrupación | `\(` `\)` | `(` `)` | Los paréntesis simples en BRE son paréntesis literales |
| Alternación | `\|` *(ext. GNU)* | `|` | **BRE de POSIX no tiene alternación en absoluto** |
| Retrorreferencia | `\1` … `\9` | `\1` … `\9` *(ext. GNU)* | Indefinida en ERE de POSIX; fuerza el motor con backtracking — ver §2.4 |
| Escape de carácter ordinario | `\.` `\$` | `\.` `\$` | Escapar un carácter ordinario *no especial* es indefinido en ERE |

**La trampa de la inversión en una línea:** `(` `)` `{` `}` `|` `+` `?` son literales en BRE y metacaracteres en ERE. `\(` `\)` `\{` `\}` `\|` `\+` `\?` son metacaracteres en BRE e indefinidos/literales en ERE.

```bash
$ echo 'a+b' | grep -c 'a+b'      # BRE: '+' is literal → match
1
$ echo 'a+b' | grep -c -E 'a+b'   # ERE: 'a+' is "one or more a" → no match
0
```

### 2.2 Clases de caracteres POSIX (sensibles al locale, portables, siempre correctas)

| Clase | Equivalente (locale C) | Usala en lugar de |
|---|---|---|
| `[[:alpha:]]` | `[A-Za-z]` | `[a-zA-Z]` |
| `[[:digit:]]` | `[0-9]` | `\d` (no es POSIX) |
| `[[:alnum:]]` | `[0-9A-Za-z]` | `\w` (GNU agrega `_`) |
| `[[:upper:]]` / `[[:lower:]]` | `[A-Z]` / `[a-z]` | rangos que se rompen con la collation |
| `[[:space:]]` | espacio, tab, NL, VT, FF, CR | `\s` (no es POSIX) |
| `[[:blank:]]` | solo espacio y tab | `[ \t]` |
| `[[:punct:]]` | imprimible, no alfanumérico, no espacio | conjuntos armados a mano |
| `[[:xdigit:]]` | `[0-9A-Fa-f]` | — |
| `[[:cntrl:]]` / `[[:print:]]` / `[[:graph:]]` | control / imprimible / imprimible-no-espacio | — |

El anidamiento es obligatorio: `[[:digit:]]` es una clase dentro de una expresión entre corchetes. `[[:digit:].-]` = dígitos, punto, guion.

### 2.3 Extensiones GNU que vas a usar a diario (y que no son portables)

| Extensión | Significado | Disponible en |
|---|---|---|
| `\b` / `\B` | límite de palabra / no-límite | GNU grep, GNU sed, gawk (`\y`), PCRE |
| `\<` / `\>` | inicio / fin de palabra | GNU grep, GNU sed |
| `\w` / `\W` | `[_[:alnum:]]` / complemento | GNU grep, GNU sed |
| `\s` / `\S` | `[[:space:]]` / complemento | GNU grep, GNU sed |
| `\|` `\+` `\?` en BRE | alternación, +, ? | GNU |
| `\`` / `\'` | inicio / fin del búfer (distinto de `^`/`$`) | GNU sed |
| `-P` | cambiar por completo a PCRE2 | GNU grep, compilado con PCRE |

Ninguno de `\b \w \s \d` es POSIX. En un `Makefile`, en el `sh` de un contenedor, en una máquina BSD o en busybox pueden ser `b`, `w`, `s`, `d` literales.

### 2.4 El panorama de motores — la tabla operativamente más importante de este objetivo

| Motor | Usado por | Sintaxis | Retrorreferencias | Look-around | Peor caso | Anclaje |
|---|---|---|---|---|---|---|
| DFA de GNU (+ respaldo de glibc) | `grep`, `grep -E`, `egrep` | BRE / ERE + ext. GNU | sí (cae a backtracking) | no | **O(n·m)** sin retrorreferencias | sin anclar |
| `regexec` de glibc | `sed`, `awk` (mawk/BWK), muchos programas en C | BRE / ERE | sí | no | puede degradarse de forma superlineal | sin anclar |
| DFA de gawk | `gawk` | ERE + `\y` `\s` | no | no | lineal | sin anclar |
| Aho–Corasick / Boyer–Moore | `grep -F`, `fgrep` | **solo literales** | n/a | n/a | lineal, ~GB/s | sin anclar |
| PCRE2 | `grep -P`, `journalctl -g`, nginx (PCRE), PHP | Perl | sí | sí | **exponencial** (protegido por un límite de coincidencias) | sin anclar |
| Onigmo | Fluent Bit, Ruby | estilo Perl, `(?<name>…)` | sí | sí | **exponencial, sin protección** | sin anclar |
| RE2 | Prometheus, Alertmanager, Loki, Envoy, `regexp` de Go | sintaxis RE2, `(?P<name>…)` | **no** | **no** | lineal, con memoria acotada | **anclado** en Prometheus/Alertmanager; **sin anclar** en Loki `|~` |
| `regex` de Rust | ripgrep, Vector | similar a RE2 | no | no | lineal | sin anclar |

Dos consecuencias que tenés que internalizar:

1. **`grep -E` no puede probar que una regex de Fluent Bit / nginx / Python sea segura.** Es otra clase de motor. Sí *puede* probar la intención sintáctica de patrones de tipo POSIX.
2. **Los motores de la familia RE2 rechazan construcciones, no se vuelven lentos.** Una retrorreferencia o un look-ahead en un `regex` de Prometheus es un error de carga de configuración, no un problema de rendimiento. Esto es una virtud: hace que el ReDoS sea estructuralmente imposible en el plano de control de métricas.

Referencia: Russ Cox, *Regular Expression Matching Can Be Simple And Fast* — https://swtch.com/~rsc/regexp/regexp1.html

### 2.5 Codicia (greediness), y por qué `.*` es un antipatrón en los parsers

POSIX exige la coincidencia **más a la izquierda y más larga** (leftmost-longest). Por eso `.*` consume hasta el final de la línea y devuelve solo lo estrictamente necesario.

```bash
$ echo '"GET /api/v2/orders HTTP/1.1" 200' | grep -oE '".*"'
"GET /api/v2/orders HTTP/1.1"
$ echo 'a"b"c"d"e' | grep -oE '".*"'
"b"c"d"
$ echo 'a"b"c"d"e' | grep -oE '"[^"]*"'
"b"
"d"
```

En los parsers de logs, el patrón correcto para un campo es casi siempre una **expresión entre corchetes negada** (`[^"]*`, `[^ ]*`, `[^\]]*`), nunca `.*?`. Es más rápido (sin backtracking), portable (los cuantificadores perezosos no son POSIX) y no ambiguo.

---

## 3. Las herramientas

### 3.1 `grep` — la superficie de opciones que importa en producción

| Opción | Efecto | Uso en producción |
|---|---|---|
| `-E` / `-F` / `-G` / `-P` | ERE / cadenas fijas / BRE (por defecto) / PCRE2 | `-F` para coincidencia de IOC y listas de bloqueo; `-P` solo cuando realmente necesitás look-around |
| `-e PAT` | patrón como argumento | obligatorio cuando el patrón empieza con `-` |
| `-f FILE` | leer patrones, uno por línea | `-F -f iocs.txt` con 50 k patrones sigue siendo ~lineal |
| `-i` `-w` `-x` `-v` | ignorar mayúsculas / palabra completa / línea completa / invertir | `-w` evita que `10.0.0.1` coincida con `110.0.0.10` |
| `-c` `-l` `-L` `-o` `-m N` | contar / archivos con / archivos sin / solo la coincidencia / parar tras N | `-m1 -l` cortocircuita en archivos enormes |
| `-n` `-H` `-h` `-b` `-Z` | n.º de línea / con nombre de archivo / sin nombre de archivo / desplazamiento en bytes / NUL tras el nombre | `-Z` + `xargs -0` para rutas con espacios |
| `-A N` `-B N` `-C N` | después / antes / contexto | stack traces |
| `-r` / `-R` | recursivo (**`-r` no sigue symlinks**, salvo los pasados en la línea de comandos) / recursivo siguiendo todos los symlinks | `-r` por defecto; `-R` arriesga bucles |
| `--include=GLOB` `--exclude=GLOB` `--exclude-dir=GLOB` | filtrado de rutas | `--exclude-dir=.git --exclude-dir=vendor` |
| `-I` / `-a` / `--binary-files=text` | saltear binarios / tratarlos como texto | logs que contienen NUL por una escritura partida |
| `-z` / `--null-data` | los registros de entrada están separados por NUL | con `find -print0`; además hace que `.` abarque saltos de línea |
| `--line-buffered` | vaciar el búfer por línea | **obligatorio** en `tail -f | grep … | while read` |
| `-q` | silencioso, sale en la primera coincidencia | condicionales; ver la nota sobre SIGPIPE en §6 |
| `-s` | suprimir mensajes de error de archivo | no la uses mientras depurás — oculta problemas de permisos |

**`egrep` y `fgrep` están obsoletos.** GNU grep 3.8 (2022) hizo que emitan `egrep: warning: egrep is obsolescent; using grep -E`. LPIC-1 v5.0 todavía los nombra, así que conocelos; en código, escribí siempre `grep -E` / `grep -F`.

### 3.2 `sed` — un editor de líneas cuyas direcciones son expresiones regulares

Estructura: `sed [-n] [-E] [-i[SUFFIX]] [-z] 'ADDRESS COMMAND' file…`

| Forma de dirección | Significado |
|---|---|
| `/re/` | líneas que coinciden con `re` |
| `\%re%` | igual, con delimitador alternativo (para rutas) |
| `N` , `$` | línea N, última línea |
| `addr1,addr2` | rango inclusivo, se puede rearmar |
| `0,/re/` | **GNU:** rango que termina en la *primera* coincidencia, incluso en la línea 1 — el modismo correcto para «solo la primera aparición» |
| `addr,+N` / `addr,~N` | N líneas más / hasta la línea divisible por N (GNU) |
| `first~step` | cada `step` líneas a partir de `first` (GNU) |
| `addr!` | negación |

Sustitución: `s/re/replacement/FLAGS`

| Bandera | Significado |
|---|---|
| `g` | todas las apariciones de la línea |
| `N` | la N-ésima aparición; `Ng` = de la N-ésima en adelante |
| `p` | imprimir (usar junto con `-n`) |
| `w file` | escribir las líneas coincidentes a un archivo |
| `I` / `i` | coincidencia sin distinguir mayúsculas (GNU) |
| `M` / `m` | multilínea: `^`/`$` coinciden en los saltos de línea internos (GNU) |
| `e` | ejecutar el resultado como comando de shell (GNU) — **nunca** sobre entrada no confiable |

En el reemplazo: `&` = la coincidencia completa, `\1`…`\9` = grupos, `\n` = salto de línea, y GNU agrega `\U \L \u \l \E` para conversión de mayúsculas/minúsculas. Una regex vacía `s//x/` reutiliza la última regex — por eso funciona `0,/ERROR/s//FIRST/`.

**`sed` está orientado a líneas.** El espacio de patrones contiene una sola línea; `^` y `$` son los bordes de esa línea. Para coincidir a través de varias líneas tenés que construir un espacio de patrones multilínea con `N`, `H`/`G`, o usar `-z` (registros separados por NUL → el archivo entero es un único registro).

Portabilidad: el `sed -i` de GNU acepta un sufijo opcional pegado (`-i.bak`); el `sed -i` de BSD **requiere** un argumento (`-i ''`). `-E` es la bandera portable para expresiones extendidas (estandarizada en POSIX Issue 8; GNU acepta `-r` como sinónimo).

### 3.3 Elección de herramienta

| Tarea | Herramienta correcta | Por qué |
|---|---|---|
| ¿Existe esta cadena literal? | `grep -F` | sin parseo de regex; Boyer–Moore |
| Coincidir con uno de 50 000 literales | `grep -F -f list.txt` | Aho–Corasick, una sola pasada |
| Extracción de campos estructurados, línea por línea | `grep -oE` o `sed -E 's/…/\1/'` | no hace falta estado |
| Extracción de campos con aritmética/agregación | `awk` | ERE + contexto numérico en una sola pasada |
| Editar in situ en todo un repositorio | `sed -E -i` guiado por `grep -rlZ` | cambia solo los archivos que coinciden |
| Correlación entre líneas | `awk` (mantener estado) o `sed -z` | la orientación a líneas es la restricción |
| Buscar en un árbol de fuentes grande | `rg` (ripgrep) si está disponible, si no `grep -r --exclude-dir` | respeta gitignore, paralelo, motor de tiempo lineal |
| Buscar en el journal | `journalctl -g PATTERN` | PCRE2, indexado, sin el costo de `journalctl | grep` |
| Buscar en logs rotados/comprimidos | `zgrep` / `xzgrep` / `zstdgrep` | evita un archivo temporal de descompresión |

---

## 4. Manifiestos de infraestructura — dónde se ejecutan realmente estas regex

Los siguientes son manifiestos completos y desplegables. Son la mitad «de producción» de este objetivo: la misma sintaxis que practicás con `grep` es la que commiteás acá.

### 4.1 Fluent Bit — parsers regex (Onigmo), la capa sensible al backtracking

```yaml
---
apiVersion: v1
kind: ServiceAccount
metadata:
  name: fluent-bit
  namespace: observability
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: fluent-bit-read
rules:
  - apiGroups: [""]
    resources:
      - namespaces
      - pods
    verbs: ["get", "list", "watch"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: fluent-bit-read
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: fluent-bit-read
subjects:
  - kind: ServiceAccount
    name: fluent-bit
    namespace: observability
---
apiVersion: v1
kind: ConfigMap
metadata:
  name: fluent-bit-config
  namespace: observability
  labels:
    app.kubernetes.io/name: fluent-bit
data:
  fluent-bit.conf: |
    [SERVICE]
        Flush                     1
        Daemon                    Off
        Log_Level                 info
        Parsers_File              parsers.conf
        HTTP_Server               On
        HTTP_Listen               0.0.0.0
        HTTP_Port                 2020
        Health_Check              On
        storage.path              /var/log/flb-storage/
        storage.sync              normal
        storage.checksum          off
        storage.backlog.mem_limit 64M

    [INPUT]
        Name                tail
        Tag                 kube.*
        Path                /var/log/containers/*.log
        Exclude_Path        /var/log/containers/*fluent-bit*.log
        multiline.parser    cri
        DB                  /var/log/flb_kube.db
        DB.locking          true
        Mem_Buf_Limit       32MB
        Skip_Long_Lines     On
        Skip_Empty_Lines    On
        Refresh_Interval    10
        storage.type        filesystem

    [FILTER]
        Name                kubernetes
        Match               kube.*
        Kube_Tag_Prefix     kube.var.log.containers.
        Merge_Log           On
        Merge_Log_Key       log_processed
        Keep_Log            Off
        K8S-Logging.Parser  On
        K8S-Logging.Exclude On
        Labels              On
        Annotations         Off
        Buffer_Size         256k

    # Structured extraction for the ingress tier. If the parser fails the record
    # is passed through untouched (Reserve_Data On) instead of being dropped.
    [FILTER]
        Name                parser
        Match               kube.var.log.containers.ingress-nginx*
        Key_Name            log
        Parser              nginx_combined
        Reserve_Data        On
        Preserve_Key        Off

    [FILTER]
        Name                parser
        Match               kube.var.log.containers.orders-api*
        Key_Name            log
        Parser              app_json_fallback_plain
        Reserve_Data        On
        Preserve_Key        On

    # Drop kube-probe noise before it costs storage. The regex here is Onigmo,
    # unanchored, applied to the value of the named key.
    [FILTER]
        Name                grep
        Match               kube.*
        Exclude             agent   ^kube-probe/

    [FILTER]
        Name                grep
        Match               kube.*
        Exclude             path    ^/(healthz|readyz|livez)$

    # Redact anything that looks like a bearer token or an AWS access key id
    # before the record leaves the node.
    [FILTER]
        Name                modify
        Match               kube.*
        Condition           Key_Value_Matches log (?i)(authorization|bearer|AKIA[0-9A-Z]{16})
        Set                 redacted true

    [OUTPUT]
        Name                loki
        Match               kube.*
        Host                loki-gateway.observability.svc.cluster.local
        Port                80
        Labels              job=fluent-bit
        Label_Keys          $kubernetes['namespace_name'],$kubernetes['container_name'],$level
        Remove_Keys         kubernetes,stream
        Line_Format         json
        Auto_Kubernetes_Labels Off
        Retry_Limit         5

  parsers.conf: |
    # ---------------------------------------------------------------------
    # Every field is a NEGATED bracket expression, never `.*`.
    # There is no nested quantifier anywhere in this file. That is the rule
    # that keeps Onigmo linear on non-matching input.
    # ---------------------------------------------------------------------
    [PARSER]
        Name        nginx_combined
        Format      regex
        Regex       ^(?<remote>[^ ]*) (?<host>[^ ]*) (?<user>[^ ]*) \[(?<time>[^\]]*)\] "(?<method>[A-Z]+) (?<path>[^ ]*) (?<proto>[^"]*)" (?<code>[0-9]{3}) (?<size>[0-9-]+) "(?<referer>[^"]*)" "(?<agent>[^"]*)"$
        Time_Key    time
        Time_Format %d/%b/%Y:%H:%M:%S %z
        Time_Keep   On
        Types       code:integer size:integer

    [PARSER]
        Name        app_json_fallback_plain
        Format      regex
        Regex       ^(?<time>[0-9]{4}-[0-9]{2}-[0-9]{2}T[^ ]+) +(?<level>[A-Z]+) +\[(?<service>[^\]]*)\] +(?<logger>[^ ]+) - (?<message>.*)$
        Time_Key    time
        Time_Format %Y-%m-%dT%H:%M:%S.%LZ
        Time_Keep   On

    [PARSER]
        Name        cri
        Format      regex
        Regex       ^(?<time>[^ ]+) (?<stream>stdout|stderr) (?<logtag>[FP]) (?<message>.*)$
        Time_Key    time
        Time_Format %Y-%m-%dT%H:%M:%S.%L%z

    [MULTILINE_PARSER]
        Name          java_stacktrace
        Type          regex
        Flush_Timeout 1000
        # state  name      regex                                  next_state
        Rule      "start_state"  "/^[0-9]{4}-[0-9]{2}-[0-9]{2}T/"  "cont"
        Rule      "cont"         "/^[\t ]+(at |\.{3}|Caused by:)/" "cont"
---
apiVersion: apps/v1
kind: DaemonSet
metadata:
  name: fluent-bit
  namespace: observability
  labels:
    app.kubernetes.io/name: fluent-bit
spec:
  selector:
    matchLabels:
      app.kubernetes.io/name: fluent-bit
  updateStrategy:
    type: RollingUpdate
    rollingUpdate:
      maxUnavailable: 1
  template:
    metadata:
      labels:
        app.kubernetes.io/name: fluent-bit
      annotations:
        prometheus.io/scrape: "true"
        prometheus.io/port: "2020"
        prometheus.io/path: "/api/v1/metrics/prometheus"
    spec:
      serviceAccountName: fluent-bit
      priorityClassName: system-node-critical
      tolerations:
        - operator: Exists
      terminationGracePeriodSeconds: 30
      containers:
        - name: fluent-bit
          image: cr.fluentbit.io/fluent/fluent-bit:3.1.9
          imagePullPolicy: IfNotPresent
          ports:
            - name: http
              containerPort: 2020
              protocol: TCP
          resources:
            requests:
              cpu: 100m
              memory: 128Mi
            limits:
              # A hard CPU limit is the containment boundary for a backtracking
              # parser: it converts "node CPU starvation" into "throttled
              # collector", which is observable via container_cpu_cfs_throttled.
              cpu: "1"
              memory: 512Mi
          livenessProbe:
            httpGet:
              path: /
              port: http
            initialDelaySeconds: 10
            periodSeconds: 10
          readinessProbe:
            httpGet:
              path: /api/v1/health
              port: http
            initialDelaySeconds: 5
            periodSeconds: 10
          securityContext:
            allowPrivilegeEscalation: false
            readOnlyRootFilesystem: true
            runAsNonRoot: false
            capabilities:
              drop: ["ALL"]
          volumeMounts:
            - name: config
              mountPath: /fluent-bit/etc/fluent-bit.conf
              subPath: fluent-bit.conf
              readOnly: true
            - name: config
              mountPath: /fluent-bit/etc/parsers.conf
              subPath: parsers.conf
              readOnly: true
            - name: varlog
              mountPath: /var/log
            - name: varlibdockercontainers
              mountPath: /var/lib/docker/containers
              readOnly: true
            - name: flb-storage
              mountPath: /var/log/flb-storage
      volumes:
        - name: config
          configMap:
            name: fluent-bit-config
        - name: varlog
          hostPath:
            path: /var/log
            type: Directory
        - name: varlibdockercontainers
          hostPath:
            path: /var/lib/docker/containers
            type: DirectoryOrCreate
        - name: flb-storage
          hostPath:
            path: /var/log/flb-storage
            type: DirectoryOrCreate
```

### 4.2 Prometheus — RE2, totalmente anclado, y la protección de cardinalidad

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: prometheus-config
  namespace: observability
data:
  prometheus.yml: |
    global:
      scrape_interval:     30s
      scrape_timeout:      10s
      evaluation_interval: 30s
      external_labels:
        cluster: prod-eu-west-1

    rule_files:
      - /etc/prometheus/rules/*.yaml

    scrape_configs:
      - job_name: kubernetes-pods
        kubernetes_sd_configs:
          - role: pod
        relabel_configs:
          # `regex` is anchored: this is ^(?:true)$ — it will NOT match "True".
          - source_labels: [__meta_kubernetes_pod_annotation_prometheus_io_scrape]
            action: keep
            regex: true

          # (.+) means "the annotation exists and is non-empty".
          - source_labels: [__meta_kubernetes_pod_annotation_prometheus_io_path]
            action: replace
            target_label: __metrics_path__
            regex: (.+)

          # Two capture groups joined in `replacement`. The optional (?::\d+)?
          # strips an existing port from __address__.
          - source_labels:
              - __address__
              - __meta_kubernetes_pod_annotation_prometheus_io_port
            action: replace
            regex: ([^:]+)(?::\d+)?;(\d+)
            replacement: $1:$2
            target_label: __address__

          # Promote every pod label to a metric label, sanitising invalid
          # characters. labelmap matches against LABEL NAMES, not values.
          - action: labelmap
            regex: __meta_kubernetes_pod_label_(.+)

          - source_labels: [__meta_kubernetes_namespace]
            action: replace
            target_label: namespace

          - source_labels: [__meta_kubernetes_pod_name]
            action: replace
            target_label: pod

          # Never scrape the sandbox/init containers.
          - source_labels: [__meta_kubernetes_pod_container_name]
            action: drop
            regex: (istio-init|linkerd-init|POD)

          # Anchoring in practice: to express "contains api" you must write it.
          - source_labels: [__meta_kubernetes_pod_label_app_kubernetes_io_name]
            action: keep
            regex: .*api.*

        metric_relabel_configs:
          # Cardinality guard: drop known-explosive series at ingestion.
          - source_labels: [__name__]
            action: drop
            regex: (container_tasks_state|container_memory_failures_total|apiserver_request_duration_seconds_bucket)

          # Drop any label whose VALUE looks like a UUID or a k8s pod suffix,
          # by rewriting it to a bounded form.
          - source_labels: [pod]
            target_label: workload
            regex: (.+?)-[0-9a-f]{8,10}-[a-z0-9]{5}
            replacement: $1
            action: replace

      - job_name: fluent-bit
        kubernetes_sd_configs:
          - role: pod
            namespaces:
              names: [observability]
        relabel_configs:
          - source_labels: [__meta_kubernetes_pod_label_app_kubernetes_io_name]
            action: keep
            regex: fluent-bit
          - source_labels: [__address__]
            action: replace
            regex: ([^:]+)(?::\d+)?
            replacement: $1:2020
            target_label: __address__
          - target_label: __metrics_path__
            replacement: /api/v1/metrics/prometheus
---
apiVersion: v1
kind: ConfigMap
metadata:
  name: prometheus-rules
  namespace: observability
data:
  regex-health.yaml: |
    groups:
      - name: regex-control-plane
        interval: 30s
        rules:
          # The alert that catches Failure Mode #2 from section 1.2.
          - alert: ScrapeTierDisappeared
            expr: absent(up{job="kubernetes-pods", namespace="prod"} == 1)
            for: 10m
            labels:
              severity: critical
              team: platform
            annotations:
              summary: "No healthy targets in job kubernetes-pods/prod"
              description: >-
                Every target vanished from service discovery. The usual cause is
                a relabel_configs `regex:` that is implicitly anchored and no
                longer matches the label values it used to match.
              runbook_url: https://runbooks.example.com/prometheus/relabel-anchoring

          # The alert that catches Failure Mode #1 from section 1.1.
          - alert: LogParserCPUSaturation
            expr: |
              rate(container_cpu_usage_seconds_total{container="fluent-bit"}[5m]) > 0.9
              and
              rate(fluentbit_input_records_total[5m]) < 100
            for: 5m
            labels:
              severity: warning
              team: observability
            annotations:
              summary: "Fluent Bit burning CPU while ingesting almost nothing"
              description: >-
                High CPU with low record throughput is the signature of
                catastrophic backtracking in a parser regex. Check the most
                recently changed [PARSER] block.

          - alert: LogRecordsDropped
            expr: rate(fluentbit_output_dropped_records_total[5m]) > 0
            for: 2m
            labels:
              severity: critical
              team: observability
            annotations:
              summary: "Fluent Bit is dropping records — log loss in progress"
```

### 4.3 Alertmanager — `matchers` con `=~` (RE2 anclado)

```yaml
apiVersion: v1
kind: Secret
metadata:
  name: alertmanager-config
  namespace: observability
type: Opaque
stringData:
  alertmanager.yml: |
    global:
      resolve_timeout: 5m

    route:
      receiver: platform-slack
      group_by: [alertname, cluster, namespace]
      group_wait: 30s
      group_interval: 5m
      repeat_interval: 4h
      routes:
        # `=~` is ANCHORED. "prod-.*" matches prod-eu and prod-us, but plain
        # "prod" would match ONLY the exact string "prod".
        - matchers:
            - severity =~ "critical|page"
            - namespace =~ "prod-.*"
          receiver: pagerduty-sre
          continue: false

        # Negated regex matcher.
        - matchers:
            - namespace !~ "(dev|staging|sandbox)-.*"
            - severity = "warning"
          receiver: platform-slack

        - matchers:
            - team = "observability"
          receiver: observability-slack

    inhibit_rules:
      - source_matchers:
          - severity = "critical"
        target_matchers:
          - severity =~ "warning|info"
        equal: [alertname, cluster, namespace]

    receivers:
      - name: platform-slack
        slack_configs:
          - api_url_file: /etc/alertmanager/secrets/slack-url
            channel: '#platform-alerts'
            send_resolved: true
            title: '[{{ .Status | toUpper }}] {{ .CommonLabels.alertname }}'
            text: '{{ range .Alerts }}{{ .Annotations.description }}{{ end }}'

      - name: observability-slack
        slack_configs:
          - api_url_file: /etc/alertmanager/secrets/slack-url
            channel: '#observability'
            send_resolved: true

      - name: pagerduty-sre
        pagerduty_configs:
          - routing_key_file: /etc/alertmanager/secrets/pd-key
            severity: critical
            description: '{{ .CommonLabels.alertname }} in {{ .CommonLabels.namespace }}'
```

### 4.4 Promtail / Loki — capturas con nombre de RE2, sin anclar

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: promtail-config
  namespace: observability
data:
  promtail.yaml: |
    server:
      http_listen_port: 3101
      grpc_listen_port: 0

    positions:
      filename: /run/promtail/positions.yaml

    clients:
      - url: http://loki-gateway.observability.svc.cluster.local/loki/api/v1/push
        tenant_id: prod

    scrape_configs:
      - job_name: kubernetes-pods
        kubernetes_sd_configs:
          - role: pod
        pipeline_stages:
          - cri: {}

          # RE2 named groups use (?P<name>...). Unanchored: this matches
          # anywhere in the line unless you write ^ yourself.
          - regex:
              expression: '^(?P<ip>[^ ]+) [^ ]+ [^ ]+ \[(?P<ts>[^\]]+)\] "(?P<method>[A-Z]+) (?P<path>[^ ]+) [^"]*" (?P<status>\d{3}) (?P<bytes>[0-9-]+)'

          - labels:
              method:
              status:

          # Bound cardinality: collapse numeric path segments BEFORE labelling.
          - replace:
              expression: '(/[0-9a-f]{8,}|/\d+)'
              replace: '/:id'
              source: path

          - timestamp:
              source: ts
              format: 02/Jan/2006:15:04:05 -0700

          - metrics:
              http_5xx_total:
                type: Counter
                description: "5xx responses parsed from the ingress log"
                source: status
                config:
                  action: inc
                  match_all: false
                  value: ""
                  # This is an RE2 match against the captured status value.
          - match:
              selector: '{namespace=~"dev-.*"}'
              action: drop

        relabel_configs:
          - source_labels: [__meta_kubernetes_pod_annotation_promtail_io_scrape]
            action: drop
            regex: false
          - source_labels: [__meta_kubernetes_namespace]
            target_label: namespace
          - source_labels: [__meta_kubernetes_pod_container_name]
            target_label: container
          - action: replace
            replacement: /var/log/pods/*$1/*.log
            separator: /
            source_labels: [__meta_kubernetes_pod_uid, __meta_kubernetes_pod_container_name]
            target_label: __path__
```

El LogQL correspondiente — notá que `|~` es RE2 **sin anclar**, lo opuesto a Prometheus:

```logql
{namespace="prod-orders", container="orders-api"}
  |~ `(?i)\b(timeout|connection refused|circuit breaker)\b`
  != `kube-probe`
  | regexp `orderId=(?P<order_id>\d+)`
  | order_id != ""
```

### 4.5 La compuerta de CI — `grep` como política de merge

```yaml
name: content-and-secret-gate

on:
  pull_request:
    branches: [main]
  push:
    branches: [main]

permissions:
  contents: read

jobs:
  regex-policy:
    runs-on: ubuntu-24.04
    steps:
      - uses: actions/checkout@v4
        with:
          fetch-depth: 0

      - name: Show tool versions (engine identity matters)
        run: |
          grep --version | head -n1
          sed --version | head -n1
          echo "PCRE support: $(grep -P '' /dev/null 2>&1 && echo yes || echo no)"

      - name: Block hardcoded credentials
        run: bash ci/checks/no-secrets.sh

      - name: Block :latest image tags in manifests
        run: |
          if grep -rInE --include='*.yaml' --include='*.yml' \
               '^[[:space:]]*image:[[:space:]]*[^[:space:]]+:latest[[:space:]]*$' manifests/; then
            echo "::error::mutable :latest tag found in a manifest"
            exit 1
          fi

      - name: Block unanchored Prometheus keep/drop regexes that were meant to be substrings
        run: bash ci/checks/relabel-anchoring.sh

      - name: Validate observability configs
        run: |
          promtool check config manifests/prometheus/prometheus.yml
          promtool check rules  manifests/prometheus/rules/*.yaml
          amtool check-config   manifests/alertmanager/alertmanager.yml
          docker run --rm -v "$PWD/manifests/fluent-bit:/cfg:ro" \
            cr.fluentbit.io/fluent/fluent-bit:3.1.9 \
            /fluent-bit/bin/fluent-bit -c /cfg/fluent-bit.conf --dry-run

      - name: Golden-corpus parser tests
        run: bash ci/checks/parser-corpus.sh
```

```bash
#!/usr/bin/env bash
# ci/checks/no-secrets.sh
# grep -E only: no PCRE, so this gate itself cannot ReDoS the runner.
set -euo pipefail

PATTERNS=$(mktemp); trap 'rm -f "$PATTERNS"' EXIT
cat >"$PATTERNS" <<'EOF'
AKIA[0-9A-Z]{16}
ASIA[0-9A-Z]{16}
-----BEGIN [A-Z ]*PRIVATE KEY-----
gh[pousr]_[A-Za-z0-9]{36,}
xox[baprs]-[0-9A-Za-z-]{10,}
eyJ[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}
(password|passwd|secret|token|api_?key)[[:space:]]*[:=][[:space:]]*["'][^"']{8,}["']
EOF

# -I skips binaries, -n gives reviewable output, --exclude-dir keeps it fast.
# Exit 1 from grep means "clean" here, so the status is inverted deliberately.
if grep -rInE -f "$PATTERNS" \
     --exclude-dir=.git \
     --exclude-dir=node_modules \
     --exclude-dir=vendor \
     --exclude-dir=.terraform \
     --exclude='*.lock' \
     --exclude='no-secrets.sh' \
     . ; then
  echo "::error::credential-shaped string found — rotate it before removing it"
  exit 1
fi

echo "no-secrets: clean"
```

```bash
#!/usr/bin/env bash
# ci/checks/relabel-anchoring.sh
# Catches the Failure Mode of section 1.2: a keep/drop regex with no
# anchor-relaxing wildcard, which is silently exact-match in Prometheus.
set -euo pipefail

status=0
while IFS= read -r hit; do
  file=${hit%%:*}
  rest=${hit#*:}
  line=${rest%%:*}
  value=$(sed -n "${line}p" "$file" | sed -E 's/^[[:space:]]*regex:[[:space:]]*//; s/^["'"'"']//; s/["'"'"']$//')

  # A regex containing no . * + ? ( ) [ ] | is a bare literal — almost always
  # an unintended exact match.
  if printf '%s' "$value" | grep -qvE '[.*+?()\[\]|]'; then
    printf '%s:%s: bare literal regex %q — Prometheus anchors this to ^(?:%s)$\n' \
      "$file" "$line" "$value" "$value"
    status=1
  fi
done < <(grep -rnE --include='*.yml' --include='*.yaml' \
           '^[[:space:]]*regex:[[:space:]]*' manifests/prometheus/ || true)

exit "$status"
```

```bash
#!/usr/bin/env bash
# ci/checks/parser-corpus.sh
# Golden corpus: every parser must match every POSITIVE sample and must match
# NO negative sample, and must do so in bounded time.
set -euo pipefail

RE_NGINX='^([^ ]*) ([^ ]*) ([^ ]*) \[([^]]*)\] "([A-Z]+) ([^ ]*) ([^"]*)" ([0-9]{3}) ([0-9-]+) "([^"]*)" "([^"]*)"$'

fail=0

while IFS= read -r line; do
  [ -z "$line" ] && continue
  if ! printf '%s\n' "$line" | timeout 5 grep -qE "$RE_NGINX"; then
    printf 'POSITIVE sample did not match: %s\n' "$line"
    fail=1
  fi
done < ci/corpus/nginx.positive

while IFS= read -r line; do
  [ -z "$line" ] && continue
  if printf '%s\n' "$line" | timeout 5 grep -qE "$RE_NGINX"; then
    printf 'NEGATIVE sample matched (regex too loose): %s\n' "$line"
    fail=1
  fi
done < ci/corpus/nginx.negative

# Pathological input must complete well inside the timeout.
if ! head -c 100000 /dev/zero | tr '\0' 'a' | timeout 5 grep -qE "$RE_NGINX"; then
  : # no match is the expected result; what matters is that it returned
fi
if [ $? -eq 124 ]; then
  echo "regex did not terminate on pathological input"
  fail=1
fi

exit "$fail"
```

---

## 5. Sesiones de terminal

### 5.1 Construir el corpus del laboratorio

```bash
$ mkdir -p ~/lab/103.7 && cd ~/lab/103.7
$ cat > access.log <<'EOF'
10.0.4.17 - - [26/Aug/2026:09:14:02 +0000] "GET /healthz HTTP/1.1" 200 2 "-" "kube-probe/1.29"
10.0.4.17 - - [26/Aug/2026:09:14:12 +0000] "GET /healthz HTTP/1.1" 200 2 "-" "kube-probe/1.29"
203.0.113.42 - - [26/Aug/2026:09:14:19 +0000] "POST /api/v2/orders HTTP/1.1" 201 512 "-" "curl/8.5.0"
198.51.100.7 - - [26/Aug/2026:09:14:23 +0000] "GET /api/v2/orders/8821 HTTP/1.1" 404 74 "-" "Go-http-client/2.0"
203.0.113.42 - - [26/Aug/2026:09:15:01 +0000] "POST /api/v2/orders HTTP/1.1" 500 141 "-" "curl/8.5.0"
192.0.2.88 - - [26/Aug/2026:09:15:07 +0000] "GET /static/app.js HTTP/1.1" 200 90211 "https://shop.example.com/" "Mozilla/5.0"
203.0.113.42 - - [26/Aug/2026:09:15:33 +0000] "POST /api/v2/orders HTTP/1.1" 502 0 "-" "curl/8.5.0"
198.51.100.7 - - [26/Aug/2026:09:15:44 +0000] "DELETE /api/v2/orders/8821 HTTP/1.1" 403 63 "-" "Go-http-client/2.0"
10.0.4.17 - - [26/Aug/2026:09:15:52 +0000] "GET /healthz HTTP/1.1" 200 2 "-" "kube-probe/1.29"
192.0.2.88 - - [26/Aug/2026:09:16:02 +0000] "GET /api/v2/cart HTTP/1.1" 200 1044 "https://shop.example.com/" "Mozilla/5.0"
203.0.113.42 - - [26/Aug/2026:09:16:19 +0000] "POST /api/v2/orders HTTP/1.1" 503 0 "-" "curl/8.5.0"
172.16.9.3 - - [26/Aug/2026:09:16:41 +0000] "GET /admin/metrics HTTP/1.1" 401 0 "-" "Prometheus/2.51.2"
EOF

$ cat > app.log <<'EOF'
2026-08-26T09:14:02.114Z INFO  [orders-api] c.e.o.web.HealthController - liveness ok
2026-08-26T09:15:01.882Z ERROR [orders-api] c.e.o.svc.OrderService - failed to reserve stock for orderId=8821 sku=SKU-4471
2026-08-26T09:15:01.883Z ERROR [orders-api] c.e.o.svc.OrderService - java.sql.SQLTransientConnectionException: HikariPool-1 - Connection is not available, request timed out after 30000ms.
2026-08-26T09:15:01.884Z ERROR [orders-api] c.e.o.svc.OrderService -     at com.zaxxer.hikari.pool.HikariPool.createTimeoutException(HikariPool.java:696)
2026-08-26T09:15:01.885Z ERROR [orders-api] c.e.o.svc.OrderService -     at com.zaxxer.hikari.pool.HikariPool.getConnection(HikariPool.java:197)
2026-08-26T09:15:33.201Z WARN  [orders-api] c.e.o.svc.PaymentClient - upstream upstream returned 502, retrying in 200ms
2026-08-26T09:16:19.774Z ERROR [orders-api] c.e.o.svc.PaymentClient - circuit breaker OPEN after 5 consecutive failures
2026-08-26T09:16:41.010Z INFO  [orders-api] c.e.o.web.MetricsController - unauthorized scrape from 172.16.9.3
2026-08-26T09:17:02.554Z DEBUG [orders-api] c.e.o.repo.OrderRepo - select * from orders where id = ?
2026-08-26T09:17:10.099Z INFO  [orders-api] c.e.o.web.HealthController - readiness ok
EOF

$ wc -l access.log app.log
 12 access.log
 10 app.log
 22 total

$ grep --version | head -n1
grep (GNU grep) 3.11
```

### 5.2 BRE vs ERE, demostrado en lugar de memorizado

```bash
$ grep -c 'orders|cart' access.log       # BRE: '|' is a literal pipe
0
$ echo $?
1

$ grep -c 'orders\|cart' access.log      # BRE + GNU alternation extension
6

$ grep -c -E 'orders|cart' access.log    # ERE: portable and readable
6
```

Agrupación e intervalos en ambos dialectos:

```bash
$ grep -oE '^([0-9]{1,3}\.){3}[0-9]{1,3}' access.log | head -n3
10.0.4.17
10.0.4.17
203.0.113.42

$ grep -o '^\([0-9]\{1,3\}\.\)\{3\}[0-9]\{1,3\}' access.log | head -n3
10.0.4.17
10.0.4.17
203.0.113.42
```

Las anclas son posicionales en BRE y absolutas en ERE:

```bash
$ echo 'a^b' | grep -c 'a^b'      # BRE: '^' not at the start → literal
1
$ echo 'a^b' | grep -c -E 'a^b'   # ERE: '^' always an anchor → impossible
0
$ echo 'a$b' | grep -c 'a$b'
1
$ echo 'a$b' | grep -c -E 'a$b'
0
```

Retrorreferencias — disponibles en el BRE de GNU y (como extensión) en el ERE de GNU:

```bash
$ grep -n '\b\([a-z]\+\) \1\b' app.log
6:2026-08-26T09:15:33.201Z WARN  [orders-api] c.e.o.svc.PaymentClient - upstream upstream returned 502, retrying in 200ms
```

Ese único patrón es también lo que **nunca** hay que llevar a un motor con backtracking sobre entrada no confiable, y lo que RE2 va a rechazar de plano.

### 5.3 Búsquedas con forma de incidente

Cada 5xx servido por el ingress:

```bash
$ grep -E '" 5[0-9]{2} ' access.log
203.0.113.42 - - [26/Aug/2026:09:15:01 +0000] "POST /api/v2/orders HTTP/1.1" 500 141 "-" "curl/8.5.0"
203.0.113.42 - - [26/Aug/2026:09:15:33 +0000] "POST /api/v2/orders HTTP/1.1" 502 0 "-" "curl/8.5.0"
203.0.113.42 - - [26/Aug/2026:09:16:19 +0000] "POST /api/v2/orders HTTP/1.1" 503 0 "-" "curl/8.5.0"
```

Ranking de emisores — `-o` convierte a `grep` en un extractor de campos:

```bash
$ grep -oE '^([0-9]{1,3}\.){3}[0-9]{1,3}' access.log | sort | uniq -c | sort -rn
      4 203.0.113.42
      3 10.0.4.17
      2 198.51.100.7
      2 192.0.2.88
      1 172.16.9.3
```

Histograma de códigos de estado, excluyendo el tráfico de sondas:

```bash
$ grep -v 'kube-probe' access.log | grep -oE '" [0-9]{3} ' | tr -d '" ' | sort | uniq -c | sort -rn
      3 200
      1 503
      1 502
      1 500
      1 404
      1 403
      1 401
      1 201
```

Clientes fuera de RFC1918 — no hace falta un lookahead negado; alcanza con la alternación y `-v`:

```bash
$ grep -vE '^(10\.|172\.(1[6-9]|2[0-9]|3[01])\.|192\.168\.)' access.log | grep -oE '^[^ ]+' | sort -u
192.0.2.88
198.51.100.7
203.0.113.42
```

Contexto alrededor del primer error, tal como realmente se lee un stack trace:

```bash
$ grep -n -A3 'SQLTransientConnectionException' app.log
3:2026-08-26T09:15:01.883Z ERROR [orders-api] c.e.o.svc.OrderService - java.sql.SQLTransientConnectionException: HikariPool-1 - Connection is not available, request timed out after 30000ms.
4-2026-08-26T09:15:01.884Z ERROR [orders-api] c.e.o.svc.OrderService -     at com.zaxxer.hikari.pool.HikariPool.createTimeoutException(HikariPool.java:696)
5-2026-08-26T09:15:01.885Z ERROR [orders-api] c.e.o.svc.OrderService -     at com.zaxxer.hikari.pool.HikariPool.getConnection(HikariPool.java:197)
```

La coincidencia de palabra completa evita el clásico falso positivo de IP:

```bash
$ printf '10.0.4.17\n110.0.4.170\n' | grep '10.0.4.17'
10.0.4.17
110.0.4.170
$ printf '10.0.4.17\n110.0.4.170\n' | grep -w '10\.0\.4\.17'
10.0.4.17
```

Notá que la segunda forma también escapa los puntos. Un `.` sin escapar es «cualquier carácter», que es la razón por la que `10.0.4.17` también coincide con `10a0b4c17`.

### 5.4 `sed` — extracción, redacción y ediciones quirúrgicas

Extraer un único valor y dejar de leer el archivo (`q` cortocircuita):

```bash
$ sed -n 's/.*orderId=\([0-9]\+\).*/\1/p; /orderId=/q' app.log
8821
```

Redactar todas las direcciones IPv4 antes de enviar un extracto de log a un proveedor:

```bash
$ sed -E 's/\b([0-9]{1,3}\.){3}[0-9]{1,3}\b/x.x.x.x/g' access.log | head -n3
x.x.x.x - - [26/Aug/2026:09:14:02 +0000] "GET /healthz HTTP/1.1" 200 2 "-" "kube-probe/1.29"
x.x.x.x - - [26/Aug/2026:09:14:12 +0000] "GET /healthz HTTP/1.1" 200 2 "-" "kube-probe/1.29"
x.x.x.x - - [26/Aug/2026:09:14:19 +0000] "POST /api/v2/orders HTTP/1.1" 201 512 "-" "curl/8.5.0"
```

Reescribir un log de acceso como CSV, con los grupos de captura haciendo el trabajo de campos:

```bash
$ sed -nE 's/^([^ ]+) [^ ]+ [^ ]+ \[([^]]+)\] "([A-Z]+) ([^ ]+) [^"]*" ([0-9]{3}) ([0-9-]+).*/\2,\1,\3,\4,\5,\6/p' access.log | head -n4
26/Aug/2026:09:14:02 +0000,10.0.4.17,GET,/healthz,200,2
26/Aug/2026:09:14:12 +0000,10.0.4.17,GET,/healthz,200,2
26/Aug/2026:09:14:19 +0000,203.0.113.42,POST,/api/v2/orders,201,512
26/Aug/2026:09:14:23 +0000,198.51.100.7,GET,/api/v2/orders/8821,404,74
```

Direccionamiento por rango — todo desde el primer ERROR hasta el siguiente WARN:

```bash
$ sed -n '/ERROR/,/WARN/p' app.log
2026-08-26T09:15:01.882Z ERROR [orders-api] c.e.o.svc.OrderService - failed to reserve stock for orderId=8821 sku=SKU-4471
2026-08-26T09:15:01.883Z ERROR [orders-api] c.e.o.svc.OrderService - java.sql.SQLTransientConnectionException: HikariPool-1 - Connection is not available, request timed out after 30000ms.
2026-08-26T09:15:01.884Z ERROR [orders-api] c.e.o.svc.OrderService -     at com.zaxxer.hikari.pool.HikariPool.createTimeoutException(HikariPool.java:696)
2026-08-26T09:15:01.885Z ERROR [orders-api] c.e.o.svc.OrderService -     at com.zaxxer.hikari.pool.HikariPool.getConnection(HikariPool.java:197)
2026-08-26T09:15:33.201Z WARN  [orders-api] c.e.o.svc.PaymentClient - upstream upstream returned 502, retrying in 200ms
```

`0,/re/` — reemplazar solo la **primera** coincidencia, el modismo que `s///` por sí solo no puede expresar:

```bash
$ sed '0,/ERROR/s//FIRST-ERROR/' app.log | grep -n 'ERROR' | head -n3
2:2026-08-26T09:15:01.882Z FIRST-ERROR [orders-api] c.e.o.svc.OrderService - failed to reserve stock for orderId=8821 sku=SKU-4471
3:2026-08-26T09:15:01.883Z ERROR [orders-api] c.e.o.svc.OrderService - java.sql.SQLTransientConnectionException: HikariPool-1 - Connection is not available, request timed out after 30000ms.
4:2026-08-26T09:15:01.884Z ERROR [orders-api] c.e.o.svc.OrderService -     at com.zaxxer.hikari.pool.HikariPool.getConnection(HikariPool.java:197)
```

El límite de la orientación a líneas, y las dos maneras de sortearlo:

```bash
$ sed -n '/Connection is not available/,+1{N;s/\n[[:space:]]*/ | /;p}' app.log | head -n1
2026-08-26T09:15:01.883Z ERROR [orders-api] c.e.o.svc.OrderService - java.sql.SQLTransientConnectionException: HikariPool-1 - Connection is not available, request timed out after 30000ms. | 2026-08-26T09:15:01.884Z ERROR [orders-api] c.e.o.svc.OrderService -     at com.zaxxer.hikari.pool.HikariPool.createTimeoutException(HikariPool.java:696)

$ sed -z -E 's/(SQLTransientConnectionException)[^\n]*\n[^\n]*at ([A-Za-z.]+)\(/\1 raised at \2(/' app.log | sed -n '3p'
2026-08-26T09:15:01.883Z ERROR [orders-api] c.e.o.svc.OrderService - java.sql.SQLTransientConnectionException raised at com.zaxxer.hikari.pool.HikariPool.createTimeoutException(HikariPool.java:696)
```

Edición in situ segura en todo un repositorio — buscar primero, después editar solo lo que coincidió:

```bash
$ grep -rlZ --include='*.yaml' -E 'image: +nginx:1\.25\.[0-9]+' manifests/ \
  | xargs -0 --no-run-if-empty sed -E -i.bak 's|(image: +nginx:)1\.25\.[0-9]+|\g<1>1.27.2|'
$ grep -rn 'image: nginx' manifests/ | head -n3
manifests/ingress/deployment.yaml:34:          image: nginx:1.27.2
manifests/demo/deployment.yaml:21:          image: nginx:1.27.2
$ find manifests -name '*.bak' -delete
```

(`\g<1>` es la referencia de grupo no ambigua de GNU sed — necesaria cuando el reemplazo continúa con un dígito, ya que `\11` significaría el grupo 11.)

### 5.5 Búsqueda en todo el sistema de archivos

```bash
$ grep -rIn --exclude-dir=.git --include='*.yaml' -E '^[[:space:]]*image:.*:latest[[:space:]]*$' manifests/
manifests/dev/job-migrate.yaml:23:          image: registry.example.com/migrate:latest
manifests/dev/deployment.yaml:41:          image: registry.example.com/orders-api:latest

$ grep -rlZ -E 'AKIA[0-9A-Z]{16}' --exclude-dir=.git . | xargs -0 -r ls -l
-rw-r--r--. 1 sre sre 1180 Aug 26 09:22 ./terraform/backup.tfvars.example

$ find /etc -maxdepth 2 -type f -name '*.conf' -print0 2>/dev/null \
  | xargs -0 grep -lE '^[[:space:]]*PermitRootLogin[[:space:]]+yes'
/etc/ssh/sshd_config
```

`grep -r` frente a `find -exec` — el compromiso:

| Enfoque | Costo de arranque | Maneja nombres de archivo raros | Potencia de filtrado |
|---|---|---|---|
| `grep -r --include=… --exclude-dir=…` | un proceso | sí | solo globs |
| `find … -print0 \| xargs -0 grep` | un `grep` por lote | sí, con `-print0`/`-0` | todos los predicados de `find` (`-mtime`, `-size`, `-perm`, `-user`) |
| `find … -exec grep {} \;` | un proceso **por archivo** | sí | completa | ← evitalo; usá `-exec … {} +`

Fuentes comprimidas y el journal:

```bash
$ zgrep -c ' 50[0-9] ' /var/log/nginx/access.log.2.gz
417

$ journalctl -u kubelet --since '2026-08-26 09:00' -g 'Failed to (start|create) (pod )?sandbox' -o short-iso --no-pager | head -n2
2026-08-26T09:15:04+0000 node-3 kubelet[1811]: E0826 09:15:04.882119    1811 kuberuntime_sandbox.go:72] "Failed to create sandbox for pod" err="rpc error: code = Unknown desc = failed to setup network"
2026-08-26T09:15:09+0000 node-3 kubelet[1811]: E0826 09:15:09.114553    1811 kuberuntime_manager.go:1166] "Failed to start sandbox" pod="prod-orders/orders-api-6f9c8d7b4-2xkqz"
```

### 5.6 Comportamiento del motor ante entrada adversarial — medilo vos mismo

```bash
$ python3 -c 'print("a"*40)' > redos.txt

$ time grep -E '^(a+)+b$' redos.txt
real    0m0.003s
user    0m0.002s
sys     0m0.001s
$ echo $?
1
```

El DFA de GNU grep responde «sin coincidencia» en un tiempo casi constante, sin importar el anidamiento. Ahora el mismo patrón a través de PCRE2:

```bash
$ time grep -P '^(a+)+b$' redos.txt
grep: exceeded PCRE's backtracking limit
real    0m1.284s
user    0m1.279s
sys     0m0.003s
$ echo $?
2
```

El límite de backtracking es una *baranda de protección*, no una solución — y las bibliotecas embebidas en tu pipeline de logs habitualmente no tienen esa protección:

```bash
$ time python3 -c "import re; re.match(r'^(a+)+b\$', 'a'*26)"
real    0m11.407s
user    0m11.399s
sys     0m0.004s
```

Cada `a` adicional duplica ese tiempo. Con 30 caracteres son ~3 minutos de un core, por línea de log. Esto es toda la sección 1.1 en una sola medición.

La solución es estructural, no una perilla de ajuste:

```bash
$ time grep -P '^a+b$' redos.txt        # no nested quantifier → no ambiguity
real    0m0.003s
$ echo $?
1
```

### 5.7 Rendimiento: elegí el motor más barato que pueda responder la pregunta

```bash
$ yes '203.0.113.42 - - [26/Aug/2026:09:15:01 +0000] "POST /api/v2/orders HTTP/1.1" 500 141 "-" "curl/8.5.0"' \
  | head -n 3000000 > big.log
$ ls -lh big.log
-rw-r--r--. 1 sre sre 315M Aug 26 09:41 big.log

$ time grep -c -F 'POST /api/v2/orders' big.log
3000000
real    0m0.212s

$ time grep -c 'POST /api/v2/orders' big.log
3000000
real    0m0.219s

$ time grep -c -E '"(GET|POST|PUT) /api/v2/[a-z]+ HTTP/1\.1" [0-9]{3}' big.log
3000000
real    0m1.947s

$ time grep -c -P '"(GET|POST|PUT) /api/v2/[a-z]+ HTTP/1\.1" \d{3}' big.log
3000000
real    0m3.512s

$ time LC_ALL=C grep -c -iE '"(get|post|put) /api/v2/[a-z]+ ' big.log
3000000
real    0m1.104s

$ time grep -c -iE '"(get|post|put) /api/v2/[a-z]+ ' big.log
3000000
real    0m3.986s
```

La brecha de `LC_ALL=C` es mayor justo donde más lo vas a usar: `-i` y expresiones entre corchetes sobre locales con capacidad multibyte. Para escanear logs orientados a bytes es rendimiento gratis. **No** lo uses cuando el patrón o los datos contienen caracteres no ASCII que te importan, porque la coincidencia pasa a ser byte a byte y un carácter multibyte puede quedar partido.

---

## 6. Verificación y diagnóstico de fallas

### 6.1 El código de salida es el contrato

| Herramienta | 0 | 1 | 2 | Otros |
|---|---|---|---|---|
| `grep` | al menos una línea coincidió | ninguna línea coincidió | error (regex inválida, archivo ilegible) — salvo que `-q` lo haya suprimido | 141 = SIGPIPE (ver abajo) |
| `sed` | éxito | — | error / `q` con un código explícito | `q5` sale con 5 |
| `awk` | éxito | — | error | `exit N` |

Tres riesgos de scripting que se desprenden directamente:

```bash
# 1. `set -e` + grep: "no match" is exit 1 and will kill the script.
set -euo pipefail
count=$(grep -c 'ERROR' app.log)          # aborts the script when count is 0
count=$(grep -c 'ERROR' app.log || true)  # correct
count=$(grep -c 'ERROR' app.log) || count=0   # also correct, keeps real errors visible

# 2. `grep -q` closes stdin at the first match; the writer gets SIGPIPE.
$ set -o pipefail
$ zcat huge.log.gz | grep -q 'ERROR'; echo "status=$?"
status=141
# Fix: drop pipefail for this pipeline, or use `grep -m1 -q` semantics
# downstream of a producer that tolerates EPIPE.

# 3. `-s` hides the difference between "no match" and "cannot read".
$ grep -rs 'secret' /var/lib/kubelet/ ; echo $?
1        # is this "clean" or "permission denied everywhere"? unknowable
$ sudo grep -r 'secret' /var/lib/kubelet/ >/dev/null; echo $?
0
```

### 6.2 Runbook de diagnóstico

| Síntoma | Causa probable | Comando de diagnóstico | Solución |
|---|---|---|---|
| El patrón funciona en un REPL de Perl/Python y no coincide con nada en `grep` | `\d`, `\w+?`, `(?:…)`, `(?=…)` no son POSIX | `grep -oE 'PAT' <<<'sample'` vs `grep -oP 'PAT' <<<'sample'` | reescribilo en ERE (`[[:digit:]]`, clases negadas) o aceptá `-P` y su costo |
| `grep: Unmatched ( or \(` | metacarácter de ERE usado bajo BRE | pasar el mismo patrón por `grep -E` | agregá `-E`, o escapá como `\(` |
| Un patrón con `+`/`?`/`|` coincide literalmente | BRE por defecto | `grep -E …` | `-E`, siempre |
| Un target de Prometheus desaparece en silencio | `regex:` está anclada | `promtool check config`, después `curl -s localhost:9090/api/v1/targets \| jq '.data.droppedTargets[0]'` | escribí `.*foo.*` cuando querés decir «contiene» |
| Una alerta se enruta al receptor equivocado | `=~` anclado, o la semántica de `continue:` | `amtool config routes test --config.file=alertmanager.yml severity=critical namespace=prod-eu` | matcher consciente del anclaje; verificá con `amtool` antes de mergear |
| Una consulta de Loki devuelve demasiado | `|~` no está anclado | agregá `^`/`$`, o usá `|=` para un literal | preferí los filtros de línea `|=` antes de `|~` — Loki los aplica primero y son baratos |
| El pod de Fluent Bit al 100 % de CPU, con pocos registros de salida | cuantificador anidado en un `Regex` de `[PARSER]` | `curl -s localhost:2020/api/v1/metrics \| jq`, después diff del último cambio de parser | eliminá el anidamiento; usá clases negadas; agregá un límite de CPU como contención |
| Fluent Bit descarta registros | se alcanzó `Mem_Buf_Limit` (a menudo consecuencia de lo anterior) | `fluentbit_output_dropped_records_total` | arreglá el parser; habilitá `storage.type filesystem` |
| `Binary file X matches` en lugar de la salida | byte NUL en un log truncado | `grep -c $'\0' -a X`; `file X` | `grep -a` o `--binary-files=text`; `-I` para saltearlo |
| `grep` sobre un pipeline `tail -f` imprime a ráfagas | buffering por bloques de 4 KiB cuando stdout es un pipe | `tail -f x \| grep --line-buffered PAT \| cat` | `--line-buffered`, o `stdbuf -oL` |
| Una clase de caracteres coincide con caracteres inesperados | collation de un locale distinto de C para los rangos | `LC_ALL=C grep …` vs `grep …` | `[[:lower:]]` en lugar de `[a-z]`; fijá `LC_ALL=C` para escaneo por bytes |
| `sed -i` falla en un runner Mac/BSD | ahí `-i` requiere un argumento | `sed --version` (GNU imprime una versión; BSD da error) | `sed -i.bak` y borrar los backups, o `sed … > tmp && mv tmp file` |
| `sed` no coincide con un patrón de dos líneas | el espacio de patrones es una sola línea | `sed -n 'N;p'` para confirmarlo | `N`/`H`+`G`, o `sed -z`, o `awk` |
| `grep: regular expression too big` | conteo de intervalo por encima del límite del motor | reducí `{n,m}` | mantenete dentro de `RE_DUP_MAX` = 255 |
| Un patrón que empieza con `-` se interpreta como opción | parseo de argumentos | `grep -e '-v-flag' file` | `-e` o `--` |

### 6.3 Un arnés de validación reutilizable

Probá la regex en **el motor que la va a ejecutar**, contra corpus positivos y negativos, con un límite de tiempo. Este script es la forma genérica de `ci/checks/parser-corpus.sh`:

```bash
#!/usr/bin/env bash
# regex-verify.sh — prove a pattern before it becomes config.
# usage: regex-verify.sh <engine> <pattern> <positive-file> <negative-file>
#        engine: bre | ere | pcre | re2
set -uo pipefail

engine=$1 pattern=$2 pos=$3 neg=$4
timeout_s=5
fail=0

match_one() {   # match_one <line> -> 0 match, 1 no match, 124 timeout, 2 error
  case "$engine" in
    bre)  printf '%s\n' "$1" | timeout "$timeout_s" grep -q    -- "$pattern" ;;
    ere)  printf '%s\n' "$1" | timeout "$timeout_s" grep -qE   -- "$pattern" ;;
    pcre) printf '%s\n' "$1" | timeout "$timeout_s" grep -qP   -- "$pattern" ;;
    re2)  timeout "$timeout_s" go run ./cmd/re2match "$pattern" "$1" ;;
    *)    echo "unknown engine: $engine" >&2; exit 64 ;;
  esac
}

check() {       # check <file> <expected 0|1>
  local file=$1 want=$2 rc
  while IFS= read -r line; do
    [ -z "$line" ] && continue
    match_one "$line"; rc=$?
    case $rc in
      124) printf 'TIMEOUT  %s\n' "$line"; fail=1 ;;
      2)   printf 'REGEXERR %s\n' "$pattern"; exit 2 ;;
      *)   if [ "$rc" -ne "$want" ]; then
             printf 'WRONG(rc=%s want=%s) %s\n' "$rc" "$want" "$line"; fail=1
           fi ;;
    esac
  done < "$file"
}

check "$pos" 0
check "$neg" 1

# Adversarial probe: long runs of the most common character in the corpus.
for n in 100 1000 10000 100000; do
  probe=$(head -c "$n" /dev/zero | tr '\0' 'a')
  match_one "$probe" >/dev/null 2>&1
  [ $? -eq 124 ] && { printf 'SUPERLINEAR at n=%s — do not ship this pattern\n' "$n"; fail=1; break; }
done

[ "$fail" -eq 0 ] && echo "OK  engine=$engine  pattern=$pattern"
exit "$fail"
```

```bash
$ ./regex-verify.sh ere '^([^ ]*) ([^ ]*) ([^ ]*) \[([^]]*)\] "([A-Z]+) ([^ ]*) ([^"]*)" ([0-9]{3}) ([0-9-]+) "([^"]*)" "([^"]*)"$' \
    ci/corpus/nginx.positive ci/corpus/nginx.negative
OK  engine=ere  pattern=^([^ ]*) ([^ ]*) ([^ ]*) \[([^]]*)\] "([A-Z]+) ([^ ]*) ([^"]*)" ([0-9]{3}) ([0-9-]+) "([^"]*)" "([^"]*)"$

$ ./regex-verify.sh pcre '^(\S+\s+)+$' ci/corpus/nginx.positive ci/corpus/nginx.negative
SUPERLINEAR at n=10000 — do not ship this pattern
```

### 6.4 Checklist previa al merge para cualquier regex que se convierta en configuración

1. **Motor identificado.** ¿Cuál de los de §2.4 la va a evaluar? Escribilo en un comentario junto al patrón.
2. **Anclaje declarado.** Anclada por la herramienta (Prometheus, Alertmanager), o por vos (`^…$`), o deliberadamente sin anclar (Loki, `grep`).
3. **Sin cuantificadores anidados.** Nada de `(x+)+`, `(x*)*`, `(x|xy)+`, ni `(…)*` alrededor de un grupo que pueda coincidir con la cadena vacía.
4. **Clases negadas, no `.*`.** Cada campo es `[^delimitador]*`.
5. **Clases POSIX, no rangos ASCII.** `[[:digit:]]` antes que `[0-9]` cuando el locale no está fijado.
6. **Existe un corpus negativo.** Un patrón validado solo contra entradas que coinciden no está validado.
7. **Prueba con límite de tiempo superada** contra una cadena adversarial de 100 kB.
8. **Configuración validada por la herramienta del proveedor**: `promtool check config`, `amtool check-config`, `fluent-bit --dry-run`, `nginx -t`, prueba de humo de consulta con `logcli`.
9. **Existe una alerta para la falla silenciosa** (`absent()` para las capas de scrape, `dropped_records_total` para los colectores).
10. **`grep -E`, no `egrep`; `grep -F`, no `fgrep`** — en cada script que commiteás.

---

## 7. Mapeo con el examen

| Lo que pide el examen | Qué tener listo |
|---|---|
| Diferencia entre BRE y ERE | la tabla de inversión de §2.1 — `( ) { } | + ?` son literales en BRE y especiales en ERE |
| Construir una regex con varios elementos notacionales | anclas, `.`, expresiones entre corchetes con rangos/negación/clases POSIX, `*` `+` `?`, `{n,m}`, agrupación, alternación, retrorreferencias |
| `grep` / `egrep` / `fgrep` | `grep -E` ≡ `egrep`; `grep -F` ≡ `fgrep`; ambos nombres viejos están obsoletos en GNU grep ≥ 3.8 |
| `sed` | `s/re/repl/flags`, formas de dirección `/re/`, `N`, `$`, `addr1,addr2`, `!`, `-n` con `p`, `-i`, `-E` |
| `regex(7)` | `man 7 regex` es la referencia de sintaxis POSIX que viene en el sistema |
| Buscar en un sistema de archivos | `grep -r` con `--include` / `--exclude-dir`, y `find -print0 \| xargs -0 grep` |

---

## 8. Referencias

**Objetivos de certificación**
- LPI, *Exam 101-500 Objectives* (LPIC-1 v5.0), objetivo 103.7 — https://www.lpi.org/our-certifications/exam-101-objectives/
- LPI, *LPIC-1 Certification* (visión general) — https://www.lpi.org/our-certifications/lpic-1-overview/

**Estándares**
- The Open Group, *POSIX.1-2024 (Issue 8), Base Definitions Chapter 9: Regular Expressions* — https://pubs.opengroup.org/onlinepubs/9799919799/basedefs/V3_chap09.html
- The Open Group, *POSIX.1-2024, `grep`* — https://pubs.opengroup.org/onlinepubs/9799919799/utilities/grep.html
- The Open Group, *POSIX.1-2024, `sed`* — https://pubs.opengroup.org/onlinepubs/9799919799/utilities/sed.html
- The Open Group, *POSIX.1-2024, `awk`* — https://pubs.opengroup.org/onlinepubs/9799919799/utilities/awk.html

**Herramientas GNU**
- GNU Project, *GNU Grep Manual* — https://www.gnu.org/software/grep/manual/grep.html
- GNU Project, *GNU Grep NEWS* (obsolescencia de `egrep`/`fgrep` en 3.8) — https://git.savannah.gnu.org/cgit/grep.git/tree/NEWS
- GNU Project, *GNU sed Manual* — https://www.gnu.org/software/sed/manual/sed.html
- GNU Project, *GNU Awk User's Guide — Regular Expressions* — https://www.gnu.org/software/gawk/manual/gawk.html#Regexp

**Páginas de manual**
- `regex(7)` — https://man7.org/linux/man-pages/man7/regex.7.html
- `grep(1)` — https://man7.org/linux/man-pages/man1/grep.1.html
- `sed(1)` — https://man7.org/linux/man-pages/man1/sed.1.html
- `journalctl(1)` (`-g`/`--grep`, PCRE2) — https://man7.org/linux/man-pages/man1/journalctl.1.html
- `locale(7)` — https://man7.org/linux/man-pages/man7/locale.7.html

**Motores de expresiones regulares**
- PCRE2, *Pattern Syntax Summary* — https://www.pcre.org/current/doc/html/pcre2syntax.html
- Google, *RE2 Syntax* — https://github.com/google/re2/wiki/Syntax
- Russ Cox, *Regular Expression Matching Can Be Simple And Fast* — https://swtch.com/~rsc/regexp/regexp1.html
- OWASP, *Regular expression Denial of Service (ReDoS)* — https://owasp.org/www-community/attacks/Regular_expression_Denial_of_Service_-_ReDoS

**Componentes de plataforma usados en los manifiestos**
- Prometheus, *Configuration — `relabel_config`* — https://prometheus.io/docs/prometheus/latest/configuration/configuration/#relabel_config
- Prometheus, *Alertmanager Configuration — route and matchers* — https://prometheus.io/docs/alerting/latest/configuration/
- Fluent Bit, *Parsers — Regular Expression* — https://docs.fluentbit.io/manual/pipeline/parsers/regular-expression
- Fluent Bit, *Filters — Grep* — https://docs.fluentbit.io/manual/pipeline/filters/grep
- Grafana Loki, *Promtail stages — `regex`* — https://grafana.com/docs/loki/latest/send-data/promtail/stages/regex/
- Grafana Loki, *LogQL — Log queries* — https://grafana.com/docs/loki/latest/query/log_queries/
- Kubernetes, *DaemonSet* — https://kubernetes.io/docs/concepts/workloads/controllers/daemonset/