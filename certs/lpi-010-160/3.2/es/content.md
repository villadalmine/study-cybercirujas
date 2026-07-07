# 3.2 Searching and Extracting Data from Files

**Peso en el examen: 3** — Este tema cubre la redirección de entrada/salida (I/O redirection), las tuberías (pipes), los comandos básicos para extraer y procesar datos de archivos, y las expresiones regulares básicas junto con `grep`.

---

## 1. Los flujos estándar (standard streams)

En Linux, todo programa que se ejecuta en la terminal tiene tres canales de comunicación abiertos por defecto:

| Flujo | Nombre | File descriptor | Destino por defecto |
|---|---|---|---|
| `stdin` | Standard input | `0` | El teclado |
| `stdout` | Standard output | `1` | La pantalla (terminal) |
| `stderr` | Standard error | `2` | La pantalla (terminal) |

Entender estos tres flujos es la base de todo el tema: la redirección y los pipes no hacen otra cosa que **reconectar** estos canales hacia archivos u otros programas.

---

## 2. Redirección de salida (output redirection)

### 2.1 Redirigir `stdout` con `>` y `>>`

El operador `>` envía la salida estándar de un comando a un archivo, **sobrescribiendo** su contenido si ya existe:

```bash
$ ls /etc > listado.txt
$ cat listado.txt
adduser.conf
alternatives
apparmor.d
...
```

El operador `>>` **agrega** (append) la salida al final del archivo sin borrar lo anterior:

```bash
$ echo "primera línea" > notas.txt
$ echo "segunda línea" >> notas.txt
$ cat notas.txt
primera línea
segunda línea
```

> ⚠️ Cuidado en el examen: `>` destruye el contenido previo del archivo. Si el objetivo es acumular datos, siempre corresponde `>>`.

### 2.2 Redirigir `stderr` con `2>`

Los mensajes de error viajan por un canal separado (`stderr`, descriptor `2`). Por eso un `>` común no los captura:

```bash
$ find /etc -name "*.conf" > resultados.txt
find: '/etc/ssl/private': Permission denied
```

El error apareció en pantalla porque solo se redirigió `stdout`. Para capturar los errores:

```bash
$ find /etc -name "*.conf" > resultados.txt 2> errores.txt
```

Variantes útiles:

```bash
# Descartar los errores (el "agujero negro" /dev/null)
$ find /etc -name "*.conf" 2> /dev/null

# Enviar stdout y stderr al mismo archivo
$ find /etc -name "*.conf" > todo.txt 2>&1
```

La notación `2>&1` significa "redirigí el descriptor 2 al mismo lugar donde apunta el descriptor 1". El orden importa: primero se redirige `stdout` al archivo y después `stderr` se le suma.

### 2.3 Redirección de entrada con `<`

El operador `<` hace que un comando lea su `stdin` desde un archivo en lugar del teclado:

```bash
$ wc -l < notas.txt
2
```

Muchos comandos aceptan el archivo como argumento directo (`wc -l notas.txt`), pero la redirección de entrada es útil con programas que solo leen de `stdin`, como `tr`:

```bash
$ tr 'a-z' 'A-Z' < notas.txt
PRIMERA LÍNEA
SEGUNDA LÍNEA
```

También existe el *here document* (`<<`), que permite pasar varias líneas escritas en la propia terminal hasta encontrar una palabra delimitadora:

```bash
$ sort << FIN
> banana
> anana
> ciruela
> FIN
anana
banana
ciruela
```

---

## 3. Pipes: encadenar comandos con `|`

Un **pipe** (`|`) conecta el `stdout` de un comando con el `stdin` del siguiente. Es el mecanismo central de la filosofía Unix: programas pequeños que hacen una sola cosa bien y se combinan entre sí.

```bash
$ ls /etc | wc -l
158
```

Aquí `ls /etc` no imprime en pantalla: su salida entra directamente a `wc -l`, que cuenta las líneas recibidas.

Los pipes se pueden encadenar sin límite:

```bash
$ cat /etc/passwd | cut -d: -f7 | sort | uniq -c | sort -nr
     18 /usr/sbin/nologin
      5 /bin/false
      2 /bin/bash
      1 /bin/sync
```

Este pipeline responde "¿qué shells se usan en el sistema y cuántas veces?": extrae el campo 7 de `/etc/passwd`, lo ordena, cuenta las repeticiones y ordena el resultado de mayor a menor.

**Diferencia clave para el examen:** `>` redirige hacia un *archivo*; `|` redirige hacia otro *comando*.

---

## 4. Comandos para extraer y procesar datos

### 4.1 `cat`, `head` y `tail`

```bash
# Mostrar el archivo completo
$ cat /etc/hostname
servidor01

# Primeras líneas (10 por defecto, -n cambia la cantidad)
$ head -n 3 /etc/passwd
root:x:0:0:root:/root:/bin/bash
daemon:x:1:1:daemon:/usr/sbin:/usr/sbin/nologin
bin:x:2:2:bin:/bin:/usr/sbin/nologin

# Últimas líneas
$ tail -n 2 /etc/passwd
sshd:x:105:65534::/run/sshd:/usr/sbin/nologin
juana:x:1000:1000:Juana:/home/juana:/bin/bash
```

Una opción muy usada en administración es `tail -f`, que muestra las últimas líneas y sigue esperando líneas nuevas — ideal para monitorear logs en vivo:

```bash
$ tail -f /var/log/syslog
```

### 4.2 `wc` — contar líneas, palabras y bytes

```bash
$ wc /etc/passwd
  29   43 1607 /etc/passwd
```

La salida es: líneas, palabras, bytes. Opciones individuales: `-l` (lines), `-w` (words), `-c` (bytes).

```bash
$ wc -l /etc/passwd
29 /etc/passwd
```

### 4.3 `sort` — ordenar líneas

```bash
$ sort nombres.txt        # orden alfabético
$ sort -r nombres.txt     # orden inverso
$ sort -n numeros.txt     # orden numérico (10 después de 9, no antes)
$ sort -u nombres.txt     # ordena y elimina duplicados
```

Ejemplo con orden numérico:

```bash
$ cat numeros.txt
10
2
33
$ sort numeros.txt        # ordena como texto: ¡incorrecto para números!
10
2
33
$ sort -n numeros.txt
2
10
33
```

### 4.4 `uniq` — eliminar líneas duplicadas consecutivas

`uniq` solo detecta duplicados **adyacentes**, por eso casi siempre se usa después de `sort`:

```bash
$ sort colores.txt | uniq
azul
rojo
verde

$ sort colores.txt | uniq -c    # contar ocurrencias
      3 azul
      1 rojo
      2 verde
```

### 4.5 `cut` — extraer columnas

`cut` extrae campos de líneas con formato de columnas. Con `-d` se indica el delimitador y con `-f` el número de campo:

```bash
$ cut -d: -f1 /etc/passwd | head -n 3
root
daemon
bin

# Varios campos a la vez
$ cut -d: -f1,7 /etc/passwd | tail -n 1
juana:/bin/bash
```

También puede cortar por posición de caracteres con `-c`:

```bash
$ echo "linux-essentials" | cut -c1-5
linux
```

---

## 5. Búsqueda de texto: `grep`

`grep` busca líneas que coincidan con un patrón e imprime las que coinciden. Es probablemente el comando más importante de este tema.

```bash
$ grep bash /etc/passwd
root:x:0:0:root:/root:/bin/bash
juana:x:1000:1000:Juana:/home/juana:/bin/bash
```

Opciones más frecuentes en el examen:

| Opción | Efecto |
|---|---|
| `-i` | Ignora mayúsculas/minúsculas (case insensitive) |
| `-v` | Invierte la búsqueda: muestra las líneas que **no** coinciden |
| `-c` | Cuenta las líneas coincidentes en lugar de mostrarlas |
| `-n` | Muestra el número de línea de cada coincidencia |
| `-r` | Busca recursivamente en directorios |
| `-E` | Habilita expresiones regulares extendidas (equivale a `egrep`) |

Ejemplos:

```bash
$ grep -i "error" /var/log/syslog | wc -l
14

$ grep -v nologin /etc/passwd     # usuarios con shell real
root:x:0:0:root:/root:/bin/bash
sync:x:4:65534:sync:/bin:/bin/sync
juana:x:1000:1000:Juana:/home/juana:/bin/bash

$ grep -n root /etc/passwd
1:root:x:0:0:root:/root:/bin/bash
```

`grep` combinado con pipes es un patrón de uso constante:

```bash
$ ps aux | grep sshd
$ history | grep "systemctl"
```

---

## 6. Expresiones regulares básicas (basic regular expressions)

Las expresiones regulares (regex) son patrones que describen conjuntos de texto. No hay que confundirlas con los *globs* del shell (`*.txt`): aunque usan símbolos parecidos, su significado es distinto. Los elementos que exige el examen:

| Símbolo | Significado |
|---|---|
| `.` | Cualquier carácter individual (uno solo) |
| `*` | Cero o más repeticiones del elemento **anterior** |
| `[abc]` | Un carácter de la lista: `a`, `b` o `c` |
| `[a-z]` | Un carácter dentro del rango |
| `[^abc]` | Un carácter que **no** esté en la lista |
| `^` | Ancla: comienzo de línea |
| `$` | Ancla: fin de línea |

Ejemplos con `grep`:

```bash
# Líneas que EMPIEZAN con "root"
$ grep "^root" /etc/passwd
root:x:0:0:root:/root:/bin/bash

# Líneas que TERMINAN en "bash"
$ grep "bash$" /etc/passwd
root:x:0:0:root:/root:/bin/bash
juana:x:1000:1000:Juana:/home/juana:/bin/bash

# "b" seguida de cualquier carácter y luego "la": matchea "bola", "bala"...
$ grep "b.la" palabras.txt
bola
bala

# "ca" seguida de cero o más "s" y luego "a": "caa", "casa", "cassa"...
$ grep "cas*a" palabras.txt
casa
caa

# Líneas que contienen un dígito
$ grep "[0-9]" datos.txt

# Líneas vacías (inicio de línea seguido inmediatamente del fin)
$ grep -c "^$" archivo.txt
```

Punto clave para el examen: en regex, `*` **no** significa "cualquier cosa" como en el shell; significa "el elemento anterior, repetido cero o más veces". El equivalente al `*` del shell sería `.*` (cualquier carácter, cero o más veces).

Con `grep -E` (extended regular expressions) se habilitan operadores adicionales como `+` (una o más repeticiones), `?` (cero o una) y `|` (alternancia):

```bash
$ grep -E "bash|sync" /etc/passwd
root:x:0:0:root:/root:/bin/bash
sync:x:4:65534:sync:/bin:/bin/sync
```

---

## 7. Ejemplo integrador

Un pipeline típico que combina casi todo el tema — "¿cuáles son las 3 direcciones IP que más aparecen en un log de acceso?":

```bash
$ cut -d' ' -f1 access.log | sort | uniq -c | sort -nr | head -n 3 > top_ips.txt 2> /dev/null
$ cat top_ips.txt
   1042 203.0.113.55
    877 198.51.100.23
    412 192.0.2.101
```

Lectura del pipeline: `cut` extrae la primera columna (la IP), `sort` agrupa las repetidas, `uniq -c` las cuenta, `sort -nr` ordena numéricamente de mayor a menor, `head -n 3` se queda con las tres primeras, `>` guarda el resultado en un archivo y `2> /dev/null` descarta posibles errores.

---

## 8. Resumen para el examen

- Tres flujos: `stdin` (0), `stdout` (1), `stderr` (2).
- `>` sobrescribe, `>>` agrega, `<` lee de un archivo, `2>` redirige errores, `2>&1` unifica errores con la salida.
- `|` conecta comandos entre sí; `>` conecta un comando con un archivo.
- Comandos de extracción: `cat`, `head`, `tail` (y `tail -f`), `wc`, `sort`, `uniq`, `cut`.
- `uniq` requiere entrada ordenada; `sort -n` para orden numérico.
- `grep` busca patrones; opciones clave: `-i`, `-v`, `-c`, `-n`, `-E`.
- Regex básicas: `.` (un carácter), `*` (repetición del anterior), `[]` (conjunto), `^` y `$` (anclas).

---

## Referencias

- LPI Learning Materials — Topic 3.2, Searching and Extracting Data from Files: https://learning.lpi.org/en/learning-materials/010-160/3/3.2/
- Objetivos oficiales del examen Linux Essentials 010-160: https://www.lpi.org/our-certifications/exam-010-objectives/
- GNU Grep Manual: https://www.gnu.org/software/grep/manual/grep.html
- GNU Coreutils Manual (`cat`, `head`, `tail`, `wc`, `sort`, `uniq`, `cut`): https://www.gnu.org/software/coreutils/manual/coreutils.html
- Bash Reference Manual — Redirections: https://www.gnu.org/software/bash/manual/html_node/Redirections.html