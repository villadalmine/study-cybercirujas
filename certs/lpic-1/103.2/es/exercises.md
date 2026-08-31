# LPIC-1 103.2 — Procesar flujos de texto utilizando filtros

**Examen:** 101-500 (LPIC-1, versión 5.0) · **Objetivo:** 103.2 · **Peso:** 3.12

**Utilidades incluidas:** `bzcat`, `cat`, `cut`, `head`, `join`, `less`, `ls`, `md5sum`, `nl`, `od`, `paste`, `pr`, `sed`, `sha256sum`, `sha512sum`, `sort`, `split`, `tail`, `tr`, `uniq`, `wc`, `xzcat`, `zcat` — más los filtros de espacios en blanco adyacentes `expand`/`unexpand`/`fmt`, que revisiones anteriores del temario listaban y que siguen apareciendo en pipelines reales.

**Requisitos previos:** una shell de Linux con GNU coreutils ≥ 8.30, GNU sed ≥ 4.5, `gzip`, `bzip2`, `xz`. Verifíquelo con `sort --version | head -n 1`. Las notas de comportamiento marcadas abajo con *(GNU)* no aplican a BusyBox ni a la cadena de herramientas BSD/macOS.

**Fuentes de referencia**

- LPI, *Exam 101 Objectives (101-500)* — https://www.lpi.org/our-certifications/exam-101-objectives/
- Manual de GNU coreutils — https://www.gnu.org/software/coreutils/manual/coreutils.html
- Manual de GNU sed — https://www.gnu.org/software/sed/manual/sed.html
- POSIX.1-2017 Shell & Utilities — https://pubs.opengroup.org/onlinepubs/9699919799/utilities/contents.html
- Manual de GNU gzip — https://www.gnu.org/software/gzip/manual/gzip.html
- XZ Utils — https://tukaani.org/xz/
- Página principal de `less` — https://www.greenwoodsoftware.com/less/

---

## Bloque 0 — Construir el conjunto de datos del laboratorio

Todos los bloques posteriores usan estos archivos. Haga este primero.

1. Cree un directorio de trabajo temporal y entre en él:

   ```bash
   mkdir -p ~/lpic1-103.2 && cd ~/lpic1-103.2
   ```

2. Cree un archivo de registros delimitado por dos puntos. Observe la línea de encabezado y los salarios duplicados deliberados:

   ```bash
   cat > employees.txt <<'EOF'
   id:name:dept:salary:hired
   1007:mora:ops:52000:2019-03-14
   1002:kim:dev:61000:2021-07-01
   1009:alvarez:ops:47500:2018-11-30
   1004:tanaka:qa:55000:2020-02-17
   1001:okoye:dev:73000:2017-05-09
   1006:silva:dev:61000:2022-09-23
   1003:novak:qa:49000:2019-08-05
   1008:haddad:ops:52000:2023-01-12
   1005:iversen:dev:68000:2016-04-28
   EOF
   ```

3. Cree un log web delimitado por espacios:

   ```bash
   cat > access.log <<'EOF'
   2026-08-20 10:11:02 GET /index.html 200 10.0.0.4
   2026-08-20 10:11:07 GET /style.css 200 10.0.0.4
   2026-08-20 10:12:44 GET /admin 403 10.0.0.9
   2026-08-20 10:13:01 POST /login 401 10.0.0.9
   2026-08-20 10:13:05 POST /login 401 10.0.0.9
   2026-08-20 10:13:09 POST /login 401 10.0.0.9
   2026-08-20 10:14:20 GET /index.html 200 10.0.0.7
   2026-08-20 10:15:00 GET /admin 403 10.0.0.9
   2026-08-20 10:16:31 GET /favicon.ico 404 10.0.0.7
   2026-08-20 10:17:02 GET /index.html 200 10.0.0.4
   EOF
   ```

4. Cree dos tablas de búsqueda pequeñas para `join`, más un archivo de configuración para `sed`:

   ```bash
   printf 'dev:okoye\nops:mora\nqa:tanaka\n' > dept-owner.txt
   printf 'dev:250000\nops:180000\nqa:120000\nsec:95000\n' > dept-budget.txt

   cat > config.conf <<'EOF'
   # main server config
   Listen 80
   ServerName old.example.com
   DocumentRoot /var/www/html
   # Listen 8080
   LogLevel warn
   EOF
   ```

5. Confirme las formas:

   ```bash
   wc -l employees.txt access.log dept-owner.txt dept-budget.txt config.conf
   ```

   ```
   10 employees.txt
   10 access.log
    3 dept-owner.txt
    4 dept-budget.txt
    6 config.conf
   33 total
   ```

**Preguntas**

- **Q0.1** `employees.txt` tiene 10 líneas pero solo 9 empleados. ¿Qué filtros posteriores corromperán silenciosamente su resultado por esa causa, y cuál es la corrección estándar de un solo comando?
- **Q0.2** `wc -l` cuenta caracteres de nueva línea, no «líneas». ¿Qué informa `wc -l` para un archivo cuya última línea no tiene salto de línea final, y qué utilidad de este objetivo es la vía más rápida para *demostrar* que al archivo le falta ese salto de línea?

---

## Bloque 1 — `cat`, `nl`, `od`: ver los bytes, no la representación

Un pipeline de filtros solo se puede depurar si se puede ver qué hay realmente en el flujo. Las terminales ocultan tabuladores, retornos de carro, espacios de no separación y BOMs. Estas tres herramientas eliminan esa ambigüedad.

1. Revele todos los caracteres no imprimibles. `cat -A` es la combinación de `-v` (no imprimibles como `^X`/`M-X`), `-E` (`$` al final de línea) y `-T` (tabulador como `^I`):

   ```bash
   printf 'a\tb\tc\n' > tabs.txt
   cat -A tabs.txt
   ```

   ```
   a^Ib^Ic$
   ```

2. Construya un archivo con finales de línea de Windows y diagnostíquelo de tres maneras distintas:

   ```bash
   printf 'alpha\r\nbeta\r\ngamma\r\n' > dos.txt
   file dos.txt
   cat -A dos.txt
   od -c dos.txt
   ```

   ```
   dos.txt: ASCII text, with CRLF line terminators
   ```
   ```
   alpha^M$
   beta^M$
   gamma^M$
   ```
   ```
   0000000   a   l   p   h   a  \r  \n   b   e   t   a  \r  \n   g   a   m
   0000020   m   a  \r  \n
   0000024
   ```

   Lea con atención la salida de `od`: los desplazamientos son **octales** por defecto, 16 bytes por línea, y la última línea `0000024` es el tamaño total (0o24 = 20 bytes).

3. Cambie la base de los desplazamientos y el formato de los bytes. `-A d` da desplazamientos decimales, `-t x1` da hexadecimal de un byte, `-A n` suprime los desplazamientos por completo:

   ```bash
   od -A d -t x1z dos.txt
   printf 'A\tB\n' | od -An -tx1
   ```

   ```
   0000000 61 6c 70 68 61 0d 0a 62 65 74 61 0d 0a 67 61 6d  >alpha..beta..gam<
   0000016 6d 61 0d 0a                                      >ma..<
   0000020
   ```
   ```
    41 09 42 0a
   ```

4. Demuestre que el recuento de bytes y el de caracteres difieren bajo UTF-8:

   ```bash
   printf 'año\n' > utf8.txt
   od -An -tx1 utf8.txt
   wc -c utf8.txt
   wc -m utf8.txt
   ```

   ```
    61 c3 b1 6f 0a
   ```
   ```
   5 utf8.txt
   4 utf8.txt
   ```

5. Numere líneas. `nl` no es `cat -n`: por defecto `nl` usa el estilo de numeración del cuerpo `t` (**t**ext — numera solo las líneas no vacías), un número de seis columnas justificado a la derecha y un separador TAB:

   ```bash
   printf 'a\n\nb\n' | nl | cat -A
   printf 'a\n\nb\n' | cat -n | cat -A
   ```

   ```
        1^Ia$
          $
        2^Ib$
   ```
   ```
        1^Ia$
        2^I$
        3^Ib$
   ```

   `nl` rellena la línea sin numerar con siete espacios en blanco —el campo numérico de seis caracteres de ancho más el separador de un carácter— de modo que la columna de texto queda alineada.

6. Controle explícitamente el formato de `nl`: `-b a` numera todas (**a**ll) las líneas, `-n rz` es justificado a la derecha (**r**ight) con ceros (**z**eros) a la izquierda, `-w` fija el ancho, `-s` fija el separador:

   ```bash
   nl -b a -n rz -w 3 -s ': ' employees.txt | head -n 3
   ```

   ```
   001: id:name:dept:salary:hired
   002: 1007:mora:ops:52000:2019-03-14
   003: 1002:kim:dev:61000:2021-07-01
   ```

7. Concatenar y comprimir secuencias de líneas en blanco: el único trabajo para el que `cat` sirve genuinamente:

   ```bash
   printf 'x\n\n\n\ny\n' | cat -s
   ```

   ```
   x

   y
   ```

**Preguntas**

- **Q1.1** En el paso 2, `wc -l dos.txt` devuelve 3 y `wc -c dos.txt` devuelve 20. Concilie esos dos números byte por byte.
- **Q1.2** `od -c` imprimió `\r` pero `od -A d -t x1z` imprimió `0d`. ¿Qué representación usaría para entregarle un informe de error a un desarrollador, y por qué `\r` es ambiguo de una manera en que `0d` no lo es?
- **Q1.3** ¿Por qué `wc -m utf8.txt` devuelve 4 en su máquina pero podría devolver 5 en la de un colega? Nombre la variable de entorno exacta involucrada.
- **Q1.4** Debe numerar *todas* las líneas, incluidas las vacías, sin ceros a la izquierda, en un script que debe correr sobre BusyBox. ¿Cuál elige, `nl` o `cat -n`, y qué pierde?
- **Q1.5** `cat file | grep pattern` es un antipatrón bien conocido. Más allá del estilo, nombre un coste *medible* del proceso `cat` extra en un pipeline sobre un archivo de 4 GB.

---

## Bloque 2 — `head` y `tail`: lecturas acotadas y flujos en vivo

1. Tome las primeras tres y las últimas tres líneas:

   ```bash
   head -n 3 employees.txt
   tail -n 3 employees.txt
   ```

   ```
   id:name:dept:salary:hired
   1007:mora:ops:52000:2019-03-14
   1002:kim:dev:61000:2021-07-01
   ```
   ```
   1003:novak:qa:49000:2019-08-05
   1008:haddad:ops:52000:2023-01-12
   1005:iversen:dev:68000:2016-04-28
   ```

2. La forma `+N` de `tail` es el eliminador de encabezados canónico. Significa «empezar **en** la línea N», no «saltar N líneas»:

   ```bash
   tail -n +2 employees.txt | head -n 2
   ```

   ```
   1007:mora:ops:52000:2019-03-14
   1002:kim:dev:61000:2021-07-01
   ```

3. La forma negativa de `head` es la imagen especular: «todas menos las últimas N» *(GNU)*:

   ```bash
   head -n -7 employees.txt
   ```

   ```
   id:name:dept:salary:hired
   1007:mora:ops:52000:2019-03-14
   1002:kim:dev:61000:2021-07-01
   ```

4. Ambas herramientas funcionan también en modo byte, que ignora por completo la estructura de líneas:

   ```bash
   head -c 20 employees.txt; echo
   tail -c 11 employees.txt
   ```

   ```
   id:name:dept:salary:
   ```
   ```
   2016-04-28
   ```

5. Imprima un rango arbitrario de líneas componiendo ambas. Solo la línea 5:

   ```bash
   head -n 5 employees.txt | tail -n 1
   sed -n '5p' employees.txt
   ```

   Ambos imprimen `1004:tanaka:qa:55000:2020-02-17`. La forma con `sed` es un solo proceso; la forma `head|tail` son dos, pero deja de leer antes, lo que importa en archivos enormes.

6. Siga un archivo en vivo. Abra una segunda terminal para el escritor:

   ```bash
   # terminal A
   tail -f /tmp/live.log
   ```
   ```bash
   # terminal B
   for i in 1 2 3; do echo "event $i"; sleep 2; done >> /tmp/live.log
   ```

   Deténgalo con `Ctrl-C`. Ahora repítalo con una rotación en el medio:

   ```bash
   # terminal A
   tail -f /tmp/live.log        # then, in terminal B:
   ```
   ```bash
   # terminal B
   mv /tmp/live.log /tmp/live.log.1 && echo "after rotate" > /tmp/live.log
   ```

   `tail -f` no muestra nada más: retiene el *inodo*, que ahora es `live.log.1`. Repita la prueba completa con `tail -F` (equivalente a `--follow=name --retry`) y la línea nueva aparece, precedida por:

   ```
   tail: /tmp/live.log: file truncated
   ```
   o
   ```
   tail: '/tmp/live.log' has become inaccessible: No such file or directory
   tail: '/tmp/live.log' has appeared;  following new file
   ```

7. Con varios archivos se añaden encabezados automáticamente; suprímalos o fuércelos con `-q` / `-v`:

   ```bash
   tail -n 1 -q employees.txt access.log
   ```

   ```
   1005:iversen:dev:68000:2016-04-28
   2026-08-20 10:17:02 GET /index.html 200 10.0.0.4
   ```

**Preguntas**

- **Q2.1** `tail -n 3` y `tail -n +3` difieren. Indique con precisión qué devuelve cada uno para un archivo de 10 líneas.
- **Q2.2** ¿Por qué `tail -n 5` sobre un *pipe* debe comportarse internamente de forma distinta a `tail -n 5` sobre un *archivo regular*? ¿Qué hace en cada caso, y cuál es la implicación de memoria?
- **Q2.3** Está observando un log de aplicación que logrotate rota cada hora con `copytruncate` desactivado. ¿Usa `-f` o `-F`, y qué sale mal exactamente con el otro?
- **Q2.4** `head -c 20` sobre un archivo UTF-8 puede producir una salida que ninguna terminal representa correctamente. Explique el modo de fallo y nombre una alternativa más segura para truncar orientado a caracteres.
- **Q2.5** Reescriba «imprimir las líneas 40 a 45 de un archivo de 90 GB» usando solo herramientas de este objetivo, y justifique el orden del pipeline en términos de eficiencia de E/S.

---

## Bloque 3 — `cut`, `paste`, `tr`: columnas y conjuntos de caracteres

1. `cut` en modo **campo** (`-f`) con un delimitador explícito (`-d`). El delimitador por defecto es TAB:

   ```bash
   cut -d: -f2,3 employees.txt
   ```

   ```
   name:dept
   mora:ops
   kim:dev
   alvarez:ops
   tanaka:qa
   okoye:dev
   silva:dev
   novak:qa
   haddad:ops
   iversen:dev
   ```

2. Demuestre que `cut` **no puede reordenar** campos: la lista de campos es un conjunto, no una secuencia:

   ```bash
   cut -d: -f3,2 employees.txt | head -n 2
   ```

   ```
   name:dept
   mora:ops
   ```

3. Cambie el separador de salida y use un rango abierto:

   ```bash
   cut -d: -f2,4 --output-delimiter=' -> ' employees.txt | head -n 3
   cut -d: -f3- employees.txt | head -n 2
   ```

   ```
   name -> salary
   mora -> 52000
   kim -> 61000
   ```
   ```
   dept:salary:hired
   ops:52000:2019-03-14
   ```

4. `cut` en modo **carácter** (`-c`) y **byte** (`-b`). Sobre el archivo UTF-8 la diferencia es visible:

   ```bash
   cut -c1-2 utf8.txt
   cut -b1-2 utf8.txt | od -An -tx1
   ```

   ```
   añ
   ```
   ```
    61 c3 0a
   ```

   `-b1-2` cortó por la mitad una secuencia multibyte y produjo un byte UTF-8 inválido.

5. `cut` trata **todos** los delimitadores como significativos: no tiene modo «squeeze». Una salida alineada y rellenada con espacios debe normalizarse primero con `tr -s`:

   ```bash
   ls -l /etc | head -n 4 | cut -d' ' -f5,9          # garbage: runs of spaces
   ls -l /etc | head -n 4 | tr -s ' ' | cut -d' ' -f5,9
   ```

   El primer comando produce campos mayormente vacíos; el segundo produce pares `size name` (los valores exactos dependen del sistema).

6. `paste` es la transpuesta de `cut`: une archivos por columnas:

   ```bash
   cut -d: -f2 employees.txt | tail -n +2 > names.txt
   cut -d: -f4 employees.txt | tail -n +2 > salaries.txt
   paste -d: names.txt salaries.txt | head -n 3
   ```

   ```
   mora:52000
   kim:61000
   alvarez:47500
   ```

7. `paste -s` (**s**erial) aplana un flujo en una sola línea: el idiomático «unir líneas con una coma»:

   ```bash
   cut -d: -f2 employees.txt | tail -n +2 | paste -sd,
   ```

   ```
   mora,kim,alvarez,tanaka,okoye,silva,novak,haddad,iversen
   ```

8. `paste` con `-` repetido lee stdin una vez por cada marcador de posición, remodelando un flujo en filas de ancho fijo:

   ```bash
   seq 1 6 | paste - - -
   ```

   ```
   1	2	3
   4	5	6
   ```

9. `tr` traduce, elimina y comprime **caracteres**, nunca cadenas, y solo lee de stdin:

   ```bash
   tr 'a-z' 'A-Z' < names.txt | paste -sd,
   tr '[:lower:]' '[:upper:]' < names.txt | head -n 1
   ```

   ```
   MORA,KIM,ALVAREZ,TANAKA,OKOYE,SILVA,NOVAK,HADDAD,IVERSEN
   ```
   ```
   MORA
   ```

10. Eliminar (`-d`), comprimir (`-s`) y complementar (`-c`):

    ```bash
    tr -d '\r' < dos.txt | od -c | head -n 1
    echo 'a    b        c' | tr -s ' '
    echo 'user=admin;host=web01' | tr -c '[:alnum:]' '\n' | tr -s '\n'
    ```

    ```
    0000000   a   l   p   h   a  \n   b   e   t   a  \n   g   a   m   m   a
    ```
    ```
    a b c
    ```
    ```
    user
    admin
    host
    web01
    ```

11. Observe la regla de conjuntos asimétricos: cuando SET2 es más corto que SET1, GNU `tr` rellena SET2 repitiendo su último carácter. `-t` (truncate) lo desactiva:

    ```bash
    echo 'abcde' | tr 'abcde' 'xy'
    echo 'abcde' | tr -t 'abcde' 'xy'
    ```

    ```
    xyyyy
    ```
    ```
    xycde
    ```

**Preguntas**

- **Q3.1** Necesita los campos 3 y 1 de `/etc/passwd`, impresos como `uid username`. Muestre por qué `cut -d: -f3,1` falla y dé una línea correcta usando solo herramientas de este objetivo.
- **Q3.2** Explique en una frase por qué `cut -d' '` es la herramienta equivocada para la salida de `ls -l` pero la correcta para `access.log`.
- **Q3.3** `tr -d '\n' < file` y `paste -sd '' file` eliminan ambos los saltos de línea. Nombre una diferencia observable en el resultado.
- **Q3.4** `tr 'a-z' 'A-Z'` y `tr '[:lower:]' '[:upper:]'` dan el mismo resultado para ASCII. Bajo `LANG=de_DE.UTF-8` y con la entrada `ä`, ¿siguen coincidiendo? Explique sobre qué opera realmente GNU `tr`.
- **Q3.5** Escriba la conversión CRLF→LF más corta y correcta de `dos.txt` in situ, usando una herramienta de este objetivo, y explique por qué `sed -i 's/\r//' dos.txt` es una trampa de portabilidad.

---

## Bloque 4 — `sort`: claves, colación y estabilidad

`sort` es el filtro de mayor apalancamiento y el peor comprendido del objetivo. Es una ordenación por mezcla externa: llena un búfer en memoria, vuelca tramos ordenados a `$TMPDIR` y los mezcla — por eso ordena entradas mayores que la RAM, pero falla cuando `/tmp` es pequeño.

1. La ordenación por defecto es una comparación lexicográfica de la línea completa bajo el locale actual:

   ```bash
   tail -n +2 employees.txt | sort | head -n 3
   ```

   ```
   1001:okoye:dev:73000:2017-05-09
   1002:kim:dev:61000:2021-07-01
   1003:novak:qa:49000:2019-08-05
   ```

2. Restrinja la comparación a una clave. `-k4,4n` significa «desde el inicio del campo 4 hasta el final del campo 4, numérico». El terminador `,4` no es decoración opcional: omitirlo hace que la clave se extienda hasta el final de línea:

   ```bash
   tail -n +2 employees.txt | sort -t: -k4,4n
   ```

   ```
   1009:alvarez:ops:47500:2018-11-30
   1003:novak:qa:49000:2019-08-05
   1007:mora:ops:52000:2019-03-14
   1008:haddad:ops:52000:2023-01-12
   1004:tanaka:qa:55000:2020-02-17
   1002:kim:dev:61000:2021-07-01
   1006:silva:dev:61000:2022-09-23
   1005:iversen:dev:68000:2016-04-28
   1001:okoye:dev:73000:2017-05-09
   ```

3. Demuestre la consecuencia de una clave sin terminador:

   ```bash
   tail -n +2 employees.txt | sort -t: -k4n | head -n 3
   ```

   La clave ahora es `52000:2019-03-14`; el análisis numérico inicial se detiene en el `:`, así que los empates se resuelven únicamente por el resto del prefijo *numérico*, y el orden de los pares 52000/61000 pasa a ser un accidente del texto final en lugar de una intención declarada.

4. Ahora la trampa de la estabilidad. Compare estos dos:

   ```bash
   tail -n +2 employees.txt | sort -t: -k4,4nr
   tail -n +2 employees.txt | sort -t: -k4,4nr -s
   ```

   ```
   1001:okoye:dev:73000:2017-05-09
   1005:iversen:dev:68000:2016-04-28
   1006:silva:dev:61000:2022-09-23
   1002:kim:dev:61000:2021-07-01
   1004:tanaka:qa:55000:2020-02-17
   1008:haddad:ops:52000:2023-01-12
   1007:mora:ops:52000:2019-03-14
   1003:novak:qa:49000:2019-08-05
   1009:alvarez:ops:47500:2018-11-30
   ```
   ```
   1001:okoye:dev:73000:2017-05-09
   1005:iversen:dev:68000:2016-04-28
   1002:kim:dev:61000:2021-07-01
   1006:silva:dev:61000:2022-09-23
   1004:tanaka:qa:55000:2020-02-17
   1007:mora:ops:52000:2019-03-14
   1008:haddad:ops:52000:2023-01-12
   1003:novak:qa:49000:2019-08-05
   1009:alvarez:ops:47500:2018-11-30
   ```

   Los pares empatados se intercambian. El manual de coreutils lo dice exactamente: cuando todas las claves comparan iguales, `sort` recurre a comparar las líneas completas *«como si no se hubiera especificado ninguna opción de ordenación distinta de `--reverse` (`-r`)»*. Por lo tanto, `-r` invierte también el desempate. `-s` (`--stable`) desactiva ese recurso y conserva el orden de entrada.

5. Ordenaciones con varias claves: departamento ascendente, luego salario descendente. Note que aquí `r` es un modificador **por clave**, no el `-r` global:

   ```bash
   tail -n +2 employees.txt | sort -t: -k3,3 -k4,4nr
   ```

   ```
   1001:okoye:dev:73000:2017-05-09
   1005:iversen:dev:68000:2016-04-28
   1002:kim:dev:61000:2021-07-01
   1006:silva:dev:61000:2022-09-23
   1007:mora:ops:52000:2019-03-14
   1008:haddad:ops:52000:2023-01-12
   1009:alvarez:ops:47500:2018-11-30
   1004:tanaka:qa:55000:2020-02-17
   1003:novak:qa:49000:2019-08-05
   ```

6. La colación del locale cambia la respuesta, no solo la presentación:

   ```bash
   printf 'b\nA\na\nB\n' > case.txt
   LC_ALL=C sort case.txt | paste -sd' '
   LC_ALL=en_US.UTF-8 sort case.txt | paste -sd' '
   ```

   ```
   A B a b
   ```
   ```
   a A b B
   ```

   Para cualquier pipeline cuya salida se compare, se sume por checksum, se pase por diff o se alimente a `uniq`, fije `LC_ALL=C`. Es además la vía más rápida: sin búsquedas en tablas de colación.

7. Los modos de comparación especializados, cada uno con su propio dominio de fallo:

   ```bash
   printf '10\n9\n1000\n' | sort -n     | paste -sd' '   # numeric
   printf '1K\n1G\n1M\n'   | sort -h     | paste -sd' '   # human-readable suffixes
   printf 'v1.10\nv1.9\nv1.2\n' | sort -V | paste -sd' '  # version strings
   printf '0.1\n0.09\n0.11\n' | sort -g  | paste -sd' '   # general numeric (floats/exponents)
   ```

   ```
   9 10 1000
   ```
   ```
   1K 1M 1G
   ```
   ```
   v1.2 v1.9 v1.10
   ```
   ```
   0.09 0.1 0.11
   ```

8. Deduplique durante la ordenación, compruebe si está ordenado sin ordenar y maneje registros delimitados por NUL:

   ```bash
   tail -n +2 employees.txt | sort -t: -k3,3 -u | cut -d: -f3 | paste -sd' '
   sort -c employees.txt ; echo "exit=$?"
   ```

   ```
   dev ops qa
   ```
   ```
   sort: employees.txt:3: disorder: 1002:kim:dev:61000:2021-07-01
   exit=1
   ```

   `-c` es la comprobación barata de precondición antes de un `join` o un `uniq`; `-C` es la misma prueba en silencio, solo mediante el estado de salida. `-z` cambia a registros terminados en NUL, para nombres de archivo que puedan contener saltos de línea.

**Preguntas**

- **Q4.1** Explique, en términos de la regla de comparación de último recurso de coreutils, por qué `sort -k4,4nr` y `sort -k4,4nr -s` produjeron órdenes distintos para las dos filas de 61000.
- **Q4.2** `sort -k2` y `sort -k2,2` son comandos diferentes. Dé una entrada concreta de dos líneas donde produzcan salidas distintas.
- **Q4.3** Un trabajo nocturno hace `sort data.txt > data.sorted` y compara el SHA-256 con el de ayer. Empezó a fallar tras una actualización de la imagen base, con entrada idéntica. Dé la causa más probable y la corrección de un solo token.
- **Q4.4** ¿Por qué `sort -n` sobre `1K 1M 1G` produce un orden inútil, y qué flag es el correcto? ¿Qué hace realmente `sort -n` con la `K`?
- **Q4.5** `sort` sobre un archivo de 200 GB muere con `sort: write failed: /tmp/sortXXXX: No space left on device`. Nombre dos flags que aborden esto sin añadir disco.
- **Q4.6** ¿Por qué `sort -u` no siempre es intercambiable con `sort | uniq`? Considere `sort -k3,3 -u`.

---

## Bloque 5 — `uniq`: adyacencia, conteo y omisión de campos

`uniq` compara únicamente líneas **adyacentes**. Esto no es una limitación que haya que sortear; es lo que hace que `uniq` sea O(1) en memoria y capaz de procesar un flujo infinito.

1. Demuestre la regla de adyacencia directamente:

   ```bash
   cut -d' ' -f4 access.log | uniq -c
   ```

   ```
         1 /index.html
         1 /style.css
         1 /admin
         3 /login
         1 /index.html
         1 /admin
         1 /favicon.ico
         1 /index.html
   ```

   `/index.html` aparece tres veces en el archivo pero nunca dos veces seguidas, así que se cuenta tres veces por separado.

2. El idiomático canónico de frecuencias `sort | uniq -c | sort -rn`:

   ```bash
   cut -d' ' -f6 access.log | sort | uniq -c | sort -rn
   ```

   ```
         5 10.0.0.9
         3 10.0.0.4
         2 10.0.0.7
   ```

   El campo del contador se imprime con `%7lu ` — un número fijo de siete columnas justificado a la derecha seguido de un espacio. El `sort -rn` final funciona porque la ordenación numérica ignora los espacios iniciales.

3. Seleccione solo duplicados (`-d`), solo únicos (`-u`) y todas las copias de cada línea repetida (`-D`):

   ```bash
   cut -d' ' -f3,4 access.log | sort | uniq -cd
   cut -d' ' -f3,4 access.log | sort | uniq -u
   ```

   ```
         2 GET /admin
         3 GET /index.html
         3 POST /login
   ```
   ```
   GET /favicon.ico
   GET /style.css
   ```

4. Agrupe todas las copias con separadores de línea en blanco — útil cuando debe ver la cola diferente de registros casi duplicados:

   ```bash
   cut -d' ' -f3,4 access.log | sort | uniq --all-repeated=separate
   ```

   ```
   GET /admin
   GET /admin

   GET /index.html
   GET /index.html
   GET /index.html

   POST /login
   POST /login
   POST /login
   ```

5. Compare solo parte de cada línea. `-f N` omite los primeros N **campos** (delimitados por espacios en blanco, no configurable), `-s N` omite N **caracteres** después de eso, `-w N` limita la comparación a N caracteres:

   ```bash
   uniq -f 2 -c access.log
   ```

   ```
         1 2026-08-20 10:11:02 GET /index.html 200 10.0.0.4
         1 2026-08-20 10:11:07 GET /style.css 200 10.0.0.4
         1 2026-08-20 10:12:44 GET /admin 403 10.0.0.9
         3 2026-08-20 10:13:01 POST /login 401 10.0.0.9
         1 2026-08-20 10:14:20 GET /index.html 200 10.0.0.7
         1 2026-08-20 10:15:00 GET /admin 403 10.0.0.9
         1 2026-08-20 10:16:31 GET /favicon.ico 404 10.0.0.7
         1 2026-08-20 10:17:02 GET /index.html 200 10.0.0.4
   ```

   Las tres líneas idénticas `POST /login 401` se colapsaron aunque sus marcas de tiempo difieren, porque los campos 1 y 2 quedaron excluidos de la comparación. La **primera** línea de cada grupo es la que se imprime.

6. La misma idea por prefijo de caracteres — colapse un log por hora, ignorando los minutos:

   ```bash
   cut -c1-13 access.log | uniq -c
   ```

   ```
        10 2026-08-20 10
   ```

7. Comparación sin distinguir mayúsculas y entrada delimitada por NUL:

   ```bash
   printf 'Error\nERROR\nerror\nwarn\n' | uniq -ci
   ```

   ```
         3 Error
         1 warn
   ```

**Preguntas**

- **Q5.1** En el paso 5, las tres líneas `POST /login` se colapsaron en una cuya marca de tiempo es `10:13:01`. ¿Cuál de las tres marcas de tiempo es esa, y cuál es la regla general?
- **Q5.2** ¿Por qué `sort` debe preceder a `uniq` en el idiomático de frecuencias, y dé un caso realista donde deliberadamente *omita* la ordenación.
- **Q5.3** `uniq -f` cuenta campos como secuencias de espacios en blanco. Sus datos están delimitados por dos puntos. ¿Cuál es la solución estándar usando solo herramientas de este objetivo?
- **Q5.4** `sort -u` y `sort | uniq` son equivalentes aquí. Reescriba el pipeline de «contar ocurrencias» para que use `sort -u` y explique por qué no puede funcionar.
- **Q5.5** Está deduplicando un flujo de log de 400 GB que llega por stdin, donde los duplicados *no* son adyacentes. Explique por qué `sort | uniq` es la arquitectura equivocada y qué propiedad de los datos necesitaría para que `uniq` por sí solo fuese viable.

---

## Bloque 6 — `sed`: el editor de flujos como filtro

Dentro de 103.2, `sed` es un filtro, no un lenguaje de scripting. Concéntrese en las direcciones, `s///`, `d`, `p` con `-n`, y `-i`.

1. La sustitución reemplaza la **primera** coincidencia por línea salvo que se indique `g`. Note la trampa de los metacaracteres: un `.` sin escapar coincide con cualquier carácter:

   ```bash
   sed 's/old.example.com/new.example.com/' config.conf | sed -n '3p'
   sed 's/old\.example\.com/new.example.com/' config.conf | sed -n '3p'
   ```

   Ambos imprimen aquí `ServerName new.example.com`, pero solo el segundo es correcto: el primero también reescribiría `oldXexampleYcom`.

2. Selectores de ocurrencia: `N` para la N-ésima coincidencia, `Ng` desde la N-ésima en adelante, `g` para todas:

   ```bash
   echo 'a:b:c:d' | sed 's/:/-/'
   echo 'a:b:c:d' | sed 's/:/-/2'
   echo 'a:b:c:d' | sed 's/:/-/2g'
   echo 'a:b:c:d' | sed 's/:/-/g'
   ```

   ```
   a-b:c:d
   a:b-c:d
   a:b-c-d
   a-b-c-d
   ```

3. Cualquier carácter puede ser el delimitador. Úselo siempre que el patrón contenga barras:

   ```bash
   sed 's|/var/www/html|/srv/www|' config.conf | sed -n '4p'
   ```

   ```
   DocumentRoot /srv/www
   ```

4. `&` es la coincidencia completa; `\1`…`\9` son grupos de captura. BRE requiere `\(` `\)`; `-E` cambia a ERE:

   ```bash
   sed -n 's/^\(LogLevel\) warn$/\1 debug/p' config.conf
   sed -E -n 's/^(Listen) ([0-9]+)$/\1 \2 # was \2/p' config.conf
   sed -n 's/[0-9]\{4\}-[0-9]\{2\}-[0-9]\{2\}/[&]/p' employees.txt | head -n 1
   ```

   ```
   LogLevel debug
   ```
   ```
   Listen 80 # was 80
   ```
   ```
   1007:mora:ops:52000:[2019-03-14]
   ```

5. `-n` más `p` convierte a `sed` en un selector. Direcciones de línea, direcciones por expresión regular, rangos, última línea y direcciones con paso *(GNU)*:

   ```bash
   sed -n '2,4p' config.conf
   sed -n '/^Listen/p' config.conf
   sed -n '$p' config.conf
   sed -n '$=' config.conf
   sed -n '0~3p' employees.txt | cut -d: -f2
   ```

   ```
   Listen 80
   ServerName old.example.com
   DocumentRoot /var/www/html
   ```
   ```
   Listen 80
   ```
   ```
   LogLevel warn
   ```
   ```
   6
   ```
   ```
   kim
   silva
   iversen
   ```

6. Borrado, negación y salida temprana. `q` después del rango hace que `sed` deje de leer: la diferencia entre recorrer 6 líneas y recorrer 60 millones:

   ```bash
   sed '/^#/d' config.conf
   sed -n '/^#/!p' config.conf
   sed -n '2,4{p}; 4q' employees.txt | cut -d: -f2
   ```

   ```
   Listen 80
   ServerName old.example.com
   DocumentRoot /var/www/html
   LogLevel warn
   ```
   ```
   Listen 80
   ServerName old.example.com
   DocumentRoot /var/www/html
   LogLevel warn
   ```
   ```
   mora
   kim
   alvarez
   ```

7. Combine expresiones con `-e`, o un script separado por puntos y comas:

   ```bash
   sed -e '/^#/d' -e 's/warn/debug/' config.conf | tail -n 1
   sed '/^#/d; s/warn/debug/' config.conf | tail -n 1
   ```

   ```
   LogLevel debug
   ```

8. Edición in situ con sufijo de respaldo. `-i` no es atómico en el sentido «seguro»: `sed` escribe un archivo temporal y lo renombra, así que la propiedad y el contexto SELinux pueden cambiar. Tome siempre el `.bak`:

   ```bash
   cp config.conf config.orig
   sed -i.bak 's/^LogLevel warn$/LogLevel debug/' config.conf
   diff config.conf.bak config.conf
   ```

   ```
   6c6
   < LogLevel warn
   ---
   > LogLevel debug
   ```

9. `y` translitera como `tr`, y `l` es el `cat -A` propio de `sed`:

   ```bash
   echo 'abc' | sed 'y/abc/xyz/'
   printf 'a\tb\n' | sed -n l
   ```

   ```
   xyz
   ```
   ```
   a\tb$
   ```

**Preguntas**

- **Q6.1** `sed 's/8080/80/' config.conf` modifica la línea comentada. Escriba una versión restringida por dirección que solo edite las líneas que no empiezan por `#`.
- **Q6.2** ¿Cuál es la diferencia entre `sed '/^#/d'` y `sed -n '/^#/!p'`? ¿Hay alguna entrada para la que difieran?
- **Q6.3** `sed -n '5000000p' huge.log` y `sed -n '5000000{p;q}' huge.log` devuelven la misma línea. Explique la diferencia de tiempo de ejecución y estímela para un archivo de 60 M de líneas.
- **Q6.4** `sed -i` sobre un archivo dentro de un volumen de contenedor montado con bind falla a veces con `Device or resource busy`. Explique el mecanismo en términos de lo que `-i` le hace realmente al inodo.
- **Q6.5** Debe reemplazar `/etc/nginx/conf.d` por `/opt/nginx/conf.d`. Escriba el comando `s` dos veces —una con `/` como delimitador y otra con `|`— y diga cuál pondría en un playbook.

---

## Bloque 7 — `join`: fusión relacional sobre una clave común

`join` es una fusión por mezcla (merge join), no una fusión por hash: ambas entradas **deben** estar ordenadas por el campo de unión bajo la misma colación, y solo mantiene un grupo en memoria. Por eso escala a archivos mayores que la RAM y por eso produce silenciosamente salida incorrecta con entradas sin ordenar.

1. Unión interna básica sobre el campo 1, delimitada por dos puntos:

   ```bash
   join -t: dept-owner.txt dept-budget.txt
   ```

   ```
   dev:okoye:250000
   ops:mora:180000
   qa:tanaka:120000
   ```

   El campo de unión se emite una sola vez, primero: el formato de salida por defecto es `0,1.2,1.3,…,2.2,2.3,…`.

2. Muestre el modo de fallo silencioso. Rompa el orden de uno de los archivos:

   ```bash
   printf 'qa:tanaka\ndev:okoye\nops:mora\n' > unsorted-owner.txt
   join -t: unsorted-owner.txt dept-budget.txt
   ```

   ```
   join: unsorted-owner.txt:2: is not sorted: dev:okoye
   qa:tanaka:120000
   ```

   `join` avisa pero continúa, y `dev` y `ops` se pierden. En un script esto debe ser un fallo duro: ordene siempre las entradas, o preceda la unión con `sort -C`.

3. La forma defensiva correcta, usando sustitución de procesos:

   ```bash
   join -t: \
     <(sort -t: -k1,1 unsorted-owner.txt) \
     <(sort -t: -k1,1 dept-budget.txt)
   ```

   ```
   dev:okoye:250000
   ops:mora:180000
   qa:tanaka:120000
   ```

4. Uniones externas: `-a N` emite las líneas no emparejables del archivo N, `-e` proporciona un relleno, `-o` nombra los campos de salida (`0` = campo de unión, `N.M` = campo M del archivo N):

   ```bash
   join -t: -a 2 -e MISSING -o 0,1.2,2.2 dept-owner.txt dept-budget.txt
   ```

   ```
   dev:okoye:250000
   ops:mora:180000
   qa:tanaka:120000
   sec:MISSING:95000
   ```

5. Anti-join — encuentre claves presentes en un solo archivo. `-v N` es el complemento de `-a N`:

   ```bash
   join -t: -v 2 -o 0,2.2 dept-owner.txt dept-budget.txt
   ```

   ```
   sec:95000
   ```

6. Unión por un campo que no es el primero. `-1` y `-2` seleccionan el campo de unión por archivo:

   ```bash
   sort -t: -k3,3 <(tail -n +2 employees.txt) > emp-by-dept.txt
   join -t: -1 3 -2 1 -o 1.2,1.4,2.2 emp-by-dept.txt dept-budget.txt
   ```

   ```
   okoye:73000:250000
   kim:61000:250000
   silva:61000:250000
   iversen:68000:250000
   mora:52000:180000
   alvarez:47500:180000
   haddad:52000:180000
   tanaka:55000:120000
   novak:49000:120000
   ```

   (El orden de las líneas dentro de un departamento sigue el `sort -k3,3` estable, es decir, el orden original del archivo.)

7. Las mayúsculas y la colación deben coincidir entre la ordenación y la unión:

   ```bash
   join -t: --check-order <(sort -t: -k1,1 dept-owner.txt) <(LC_ALL=C sort -t: -k1,1 dept-budget.txt) >/dev/null; echo "exit=$?"
   ```

   Las ordenaciones con locales mezclados son la causa más común en el mundo real de una unión que «pierde filas en producción pero funciona en mi portátil».

**Preguntas**

- **Q7.1** En el paso 2, `join` imprimió una advertencia *y* estado de salida 0 en algunas versiones de coreutils. ¿Por qué es peligroso en un script con `set -e`, y qué flag hace que el desorden sea fatal?
- **Q7.2** Ambas entradas están ordenadas con `sort` bajo `en_US.UTF-8`, pero `join` sigue descartando filas. Dé las dos causas más probables.
- **Q7.3** Explique la especificación de campos `-o` `0,1.2,2.2` campo por campo, y diga qué hace `-e` cuando `-o` está *ausente*.
- **Q7.4** Escriba el comando que lista los departamentos de `dept-owner.txt` sin entrada de presupuesto.
- **Q7.5** ¿Por qué `join` escala a entradas mayores que la memoria mientras que una búsqueda ingenua en memoria no? Nombre la clase de algoritmo y su precondición.

---

## Bloque 8 — `split`, `wc` y la familia de sumas de verificación

1. Modos de conteo. `wc` informa líneas/palabras/bytes por defecto; `-m` cuenta caracteres, `-L` la longitud de la línea más larga:

   ```bash
   wc employees.txt
   wc -L employees.txt
   wc -l < employees.txt
   ```

   ```
    10  10 315 employees.txt
   ```
   ```
   33 employees.txt
   ```
   ```
   10
   ```

   (GNU `wc` dimensiona sus columnas a partir del archivo, así que los anchos de relleno varían; los números no.) El recuento de palabras es 10 porque los registros no contienen espacios en blanco: cada línea es una «palabra». Use `wc -l < file` cuando el nombre de archivo en la salida rompería el análisis posterior.

2. Divida por cantidad de líneas, con sufijos numéricos rellenados con ceros y una extensión real:

   ```bash
   seq 1 100 > numbers.txt
   split -l 30 -d --additional-suffix=.part numbers.txt chunk_
   wc -l chunk_*.part
   ```

   ```
    30 chunk_00.part
    30 chunk_01.part
    30 chunk_02.part
    10 chunk_03.part
   100 total
   ```

3. Divida por tamaño y por cantidad. `-n l/N` divide en N archivos **por límites de línea**; `-n N` a secas divide por tamaño en bytes y cortará una línea por la mitad; `-n r/N` distribuye en round-robin:

   ```bash
   rm -f chunk_*.part
   split -n l/3 -d numbers.txt lines_
   wc -l lines_*
   split -b 100 -d numbers.txt bytes_
   head -c 40 bytes_01 | od -c | head -n 2
   ```

   ```
    34 lines_00
    33 lines_01
    33 lines_02
   100 total
   ```

4. Verifique un viaje de ida y vuelta con una suma de verificación criptográfica. Este es el patrón de producción para transferencias en fragmentos:

   ```bash
   sha256sum numbers.txt > numbers.sha256
   cat lines_0* > rebuilt.txt
   sed 's/  numbers\.txt$/  rebuilt.txt/' numbers.sha256 | sha256sum -c
   ```

   ```
   rebuilt.txt: OK
   ```

5. Entienda el formato del archivo de sumas de verificación. Dos espacios separan el hash del nombre de archivo en modo texto; un espacio más `*` marca el modo binario:

   ```bash
   sha256sum numbers.txt
   sha256sum -b numbers.txt
   md5sum numbers.txt
   ```

   ```
   d8f... (64 hex chars)  numbers.txt
   ```
   ```
   d8f... (64 hex chars) *numbers.txt
   ```
   ```
   ... (32 hex chars)  numbers.txt
   ```

   Las longitudes de hash son fijas y son la vía más rápida para identificar un resumen sin etiquetar: 32 caracteres hex = MD5, 64 = SHA-256, 128 = SHA-512.

6. Modos de verificación y sus estados de salida:

   ```bash
   sha256sum -c --quiet numbers.sha256; echo "exit=$?"
   echo "corrupt" >> numbers.txt
   sha256sum -c --status numbers.sha256; echo "exit=$?"
   sed -i '$d' numbers.txt
   ```

   ```
   exit=0
   ```
   ```
   exit=1
   ```

   `--quiet` suprime las líneas `OK` pero sigue informando los fallos; `--status` suprime toda la salida y se comunica solo mediante el estado de salida: la forma correcta dentro de un condicional.

7. Las sumas de verificación leen stdin, lo que las hace componibles con cualquier filtro:

   ```bash
   tail -n +2 employees.txt | sort | sha256sum
   tail -n +2 employees.txt | LC_ALL=C sort | sha256sum
   ```

   Son posibles dos resúmenes distintos a partir de la misma entrada, por la razón establecida en el Bloque 4.

**Preguntas**

- **Q8.1** `wc employees.txt` informó 10 palabras para 10 líneas. Explíquelo y prediga `wc -w access.log`.
- **Q8.2** `split -n 3 file` y `split -n l/3 file` difieren. Para un log orientado a líneas, ¿cuál es el correcto y qué sale mal exactamente con el otro?
- **Q8.3** Dividió un archivo en 250 fragmentos con `split -d`. `cat x* > rebuilt` produce un archivo corrupto. Nombre el mecanismo y el flag que lo previene.
- **Q8.4** Tanto `md5sum` como `sha256sum` detectan corrupción accidental. Indique el único modelo de amenaza en el que `md5sum` es inaceptable y `sha256sum` no.
- **Q8.5** ¿Por qué `sha256sum -c --status` pertenece a una sentencia `if` mientras que `sha256sum -c` pertenece a una terminal interactiva?
- **Q8.6** Dos equipos calculan la suma de verificación del «mismo» archivo ordenado y obtienen resúmenes distintos. Dé la causa individual más probable y la corrección.

---

## Bloque 9 — Flujos comprimidos: `zcat`, `bzcat`, `xzcat`

Estos no son «descomprimir y luego leer»; son descompresores de **flujo** que escriben en stdout y nunca tocan el archivo de origen. Eso es lo que abarata los pipelines con salida temprana.

1. Produzca los tres formatos de archivo, conservando los originales:

   ```bash
   gzip  -k -f numbers.txt
   bzip2 -k -f numbers.txt
   xz    -k -f numbers.txt
   ls -l numbers.txt*
   ```

   `-k` (`--keep`) requiere gzip ≥ 1.6; en sistemas más antiguos use `gzip -c numbers.txt > numbers.txt.gz`.

2. Lea cada uno sin materializar un archivo temporal:

   ```bash
   zcat  numbers.txt.gz  | tail -n 3 | paste -sd' '
   bzcat numbers.txt.bz2 | wc -l
   xzcat numbers.txt.xz  | head -n 2 | paste -sd' '
   ```

   ```
   98 99 100
   ```
   ```
   100
   ```
   ```
   1 2
   ```

3. Confirme la propiedad de salida temprana. La descompresión se detiene en cuanto `head` cierra el pipe:

   ```bash
   seq 1 20000000 | gzip > big.gz
   time zcat big.gz | head -n 5
   time zcat big.gz > /dev/null
   ```

   El primero termina en milisegundos; el segundo descomprime el archivo entero. `head` termina, el extremo de escritura del pipe se rompe, `zcat` recibe `SIGPIPE` y muere.

4. `zcat -f` pasa la entrada no gzip sin modificar, lo que permite que un mismo pipeline maneje entradas mixtas:

   ```bash
   zcat -f numbers.txt numbers.txt.gz | wc -l
   ```

   ```
   200
   ```

5. La pila completa sobre un log comprimido — el patrón que realmente ejecutará en producción:

   ```bash
   gzip -c access.log > access.log.gz
   zcat access.log.gz | sed -n '/ 40[13] /p' | cut -d' ' -f6 | sort | uniq -c | sort -rn
   ```

   ```
         5 10.0.0.9
   ```

6. Conozca a los acompañantes: `zless`, `zgrep`, `zdiff`, `bzless`, `xzless`. Y conozca las herramientas de identificación — la extensión puede mentir:

   ```bash
   file numbers.txt.gz numbers.txt.bz2 numbers.txt.xz
   ```

   ```
   numbers.txt.gz:  gzip compressed data, was "numbers.txt", ...
   numbers.txt.bz2: bzip2 compressed data, block size = 900k
   numbers.txt.xz:  XZ compressed data, checksum CRC64
   ```

**Preguntas**

- **Q9.1** `zcat huge.gz | head -n 5` devuelve al instante sobre un archivo de 40 GB, mientras que `gunzip huge.gz && head -n 5 huge` tarda minutos. Explique las dos razones distintas.
- **Q9.2** ¿Por qué `zcat` puede posicionarse en la línea 5 de forma barata pero no en la línea 5 000 000? ¿Qué propiedad del flujo DEFLATE fuerza esto?
- **Q9.3** Un script de envío de logs falla en hosts donde `bzip2` no está instalado pero funciona en el resto. ¿Qué utilidad de este objetivo *no* forma parte de coreutils, y qué implica eso para las imágenes de contenedor mínimas?
- **Q9.4** Dé la línea única que cuenta el total de líneas de `app.log`, `app.log.1` y `app.log.2.gz` en una sola pasada.
- **Q9.5** `zcat file.Z` funciona en algunos sistemas y falla en otros. ¿Qué es `.Z`, y qué le dice eso sobre la implementación de `zcat`?

---

## Bloque 10 — `pr`, `less`, filtros de espacios en blanco y diagnóstico de pipelines

1. `pr` pagina para impresión. `-t` omite encabezados y pies, `-n` numera líneas (5 dígitos + TAB por defecto), `-w` fija el ancho de página:

   ```bash
   pr -t -n -w 40 employees.txt | head -n 3
   ```

   ```
       1	id:name:dept:salary:hired
       2	1007:mora:ops:52000:2019-03-14
       3	1002:kim:dev:61000:2021-07-01
   ```

2. `pr -m` fusiona archivos lado a lado en columnas — la única herramienta del objetivo que hace esto:

   ```bash
   pr -m -t -w 40 dept-owner.txt dept-budget.txt
   ```

   ```
   dev:okoye           dev:250000
   ops:mora            ops:180000
   qa:tanaka           qa:120000
                       sec:95000
   ```

   (El relleno de columnas se deriva de `-w` dividido por la cantidad de columnas; ajuste `-w` y vuelva a ejecutarlo para verlo moverse.)

3. `pr -N` reformatea un solo archivo en N columnas, primero hacia abajo y luego a lo ancho:

   ```bash
   seq 1 12 | pr -4 -t -w 40
   ```

   ```
   1		4		7		10
   2		5		8		11
   3		6		9		12
   ```

4. Normalización de espacios en blanco. `expand` convierte tabuladores en espacios; `unexpand -a` convierte secuencias de espacios de vuelta a tabuladores; sin `-a` solo toca los espacios iniciales:

   ```bash
   expand -t 4 tabs.txt | cat -A
   expand tabs.txt | cat -A
   expand -t 4 tabs.txt | unexpand -a -t 4 | cat -A
   ```

   ```
   a   b   c$
   ```
   ```
   a       b       c$
   ```
   ```
   a^Ib^Ic$
   ```

5. `fmt` reformatea prosa a un ancho objetivo. No es un ajustador voraz: optimiza los saltos de línea a lo largo del párrafo, así que verifique en lugar de predecir:

   ```bash
   cat > notes.txt <<'EOF'
   The sort utility reads lines, compares them with the current locale
   collation, and writes them in order. It buffers in memory and spills to
   temporary files when the input exceeds the buffer, which is why it can
   sort inputs larger than RAM.
   EOF
   fmt -w 40 notes.txt | wc -L
   fmt -w 40 -s notes.txt | head -n 3
   ```

   `wc -L` debe informar un valor ≤ 40. `-s` divide las líneas largas pero nunca une las cortas: la opción correcta para reformatear comentarios de código sin fusionar párrafos.

6. `less` — interactivo, pero el consumidor más importante de un filtro. Ejecute `less employees.txt` y practique:

   | Tecla | Efecto |
   |---|---|
   | `space` / `b` | avanzar / retroceder una página |
   | `g` / `G` | primera línea / última línea |
   | `/ops` luego `n` / `N` | buscar hacia adelante, coincidencia siguiente / anterior |
   | `?ops` | buscar hacia atrás |
   | `-N` `Enter` | alternar números de línea |
   | `-S` `Enter` | alternar corte de líneas en lugar de ajuste |
   | `&dev` `Enter` | mostrar **solo** las líneas coincidentes; `&` `Enter` limpia el filtro |
   | `F` | modo seguimiento, como `tail -f`; `Ctrl-C` vuelve a lo normal |
   | `=` | posición actual y estadísticas del archivo |
   | `q` | salir |

   Luego compare el comportamiento de seguimiento en vivo:

   ```bash
   less +F /var/log/syslog      # or /var/log/messages
   ```

7. **SIGPIPE y el estado de salida del pipeline.** Esta es la habilidad de diagnóstico que separa un pipeline que funciona de uno que es correcto:

   ```bash
   seq 1 1000000 | head -n 5 > /dev/null
   echo "${PIPESTATUS[@]}"
   ```

   ```
   141 0
   ```

   141 = 128 + 13 = terminado por `SIGPIPE`. Eso es normal y esperado. Ahora:

   ```bash
   set -o pipefail
   seq 1 1000000 | head -n 5 > /dev/null; echo "exit=$?"
   set +o pipefail
   ```

   ```
   exit=141
   ```

   `pipefail` convierte una salida temprana sana en un fallo del script. Bajo `set -euo pipefail`, cualquier pipeline que termine en `head` es un error latente.

8. **Almacenamiento en búfer.** libc usa búfer por líneas hacia un TTY y búfer por bloques de 4 KB hacia un pipe. Por eso un pipeline largo parece colgarse:

   ```bash
   tail -f /tmp/live.log | cut -d' ' -f2 | tr 'a-z' 'A-Z'
   ```

   Arréglelo forzando el búfer por líneas en las etapas intermedias:

   ```bash
   tail -f /tmp/live.log | stdbuf -oL cut -d' ' -f2 | stdbuf -oL tr 'a-z' 'A-Z'
   ```

   `sed` trae `-u` (`--unbuffered`) incorporado; `grep` tiene `--line-buffered`.

9. **`tee`** bifurca un flujo para que pueda inspeccionar una etapa intermedia sin volver a ejecutar todo:

   ```bash
   tail -n +2 employees.txt \
     | tee /tmp/stage1.txt \
     | cut -d: -f3 \
     | tee /tmp/stage2.txt \
     | sort | uniq -c
   wc -l /tmp/stage1.txt /tmp/stage2.txt
   ```

   ```
         4 dev
         3 ops
         2 qa
   ```
   ```
    9 /tmp/stage1.txt
    9 /tmp/stage2.txt
   18 total
   ```

**Preguntas**

- **Q10.1** `echo "${PIPESTATUS[@]}"` imprimió `141 0`. Decodifique 141 y diga si este pipeline tuvo éxito.
- **Q10.2** Su CI ejecuta `set -euo pipefail`. Un paso que hace `zcat huge.gz | head -n 100 > sample.txt` falla de forma intermitente. Diagnostíquelo y dé dos correcciones distintas.
- **Q10.3** `tail -f app.log | cut -d' ' -f5` no imprime nada durante minutos y luego suelta una ráfaga. Nombre el mecanismo, el tamaño de búfer involucrado y la corrección.
- **Q10.4** `expand` y `unexpand -a` se describen como inversos. Dé una entrada concreta donde `unexpand -a -t 4 | expand -t 4` **no** devuelva el original.
- **Q10.5** En `less`, ¿qué hace `&pattern` que `/pattern` no hace, y por qué importa eso en un log de 2 GB?
- **Q10.6** ¿Por qué es preferible `less` a `more` para un archivo que se está escribiendo activamente, y por qué es preferible `less +F` a `tail -f` cuando necesita desplazarse hacia atrás?

---

## Capstone — tres pipelines de producción

Resuelva cada uno usando solo utilidades de este objetivo. Sin `awk`, sin `grep`, sin `perl`.

1. **Cantidad de personas por departamento, con formato `dept:count`, primero el más numeroso.**

   ```bash
   tail -n +2 employees.txt \
     | cut -d: -f3 \
     | sort \
     | uniq -c \
     | sort -rn \
     | sed 's/^ *\([0-9][0-9]*\) \(.*\)$/\2:\1/'
   ```

   ```
   dev:4
   ops:3
   qa:2
   ```

2. **Quien más gana en cada departamento, un registro por departamento.**

   ```bash
   tail -n +2 employees.txt \
     | sort -t: -k3,3 -k4,4nr \
     | sort -t: -k3,3 -u
   ```

   ```
   1001:okoye:dev:73000:2017-05-09
   1007:mora:ops:52000:2019-03-14
   1004:tanaka:qa:55000:2020-02-17
   ```

3. **IPs de cliente con tres o más fallos de autenticación (HTTP 401/403), a partir del log comprimido con gzip.**

   ```bash
   zcat access.log.gz \
     | sed -n '/ 40[13] /p' \
     | cut -d' ' -f6 \
     | sort \
     | uniq -c \
     | sed -n 's/^ *\([3-9][0-9]*\|[0-9]\{2,\}\) \(.*\)$/\2 (\1 failures)/p'
   ```

   ```
   10.0.0.9 (5 failures)
   ```

**Preguntas**

- **QC.1** En el capstone 2, ¿por qué el segundo `sort -t: -k3,3 -u` conserva la fila **mejor pagada** de cada departamento en lugar de una arbitraria? ¿Qué propiedad de GNU `sort` es la que sostiene todo, y qué rompería el pipeline?
- **QC.2** El capstone 2 produce un resultado determinista para `ops` aunque `mora` y `haddad` ganan ambos 52000. Trace el desempate.
- **QC.3** Reescriba el capstone 1 para que la salida sea `count dept` separada por un único espacio, sin `sed`.
- **QC.4** La lógica del umbral del capstone 3 vive en una expresión regular. Indique la fragilidad que eso introduce y describa un enfoque basado en `sort` que no codifique el umbral en un patrón.
- **QC.5** Añada `LC_ALL=C` a los tres capstones. ¿En cuál cambia la salida, y por qué?

---

## Limpieza

```bash
cd ~ && rm -rf ~/lpic1-103.2 /tmp/live.log /tmp/live.log.1 /tmp/stage1.txt /tmp/stage2.txt
```

---

<details>
<summary><strong>Respuestas</strong></summary>

### Bloque 0

**A0.1** — Cualquier filtro que trate cada línea como dato: `sort` (el encabezado se ordena hacia el medio o, con `-k4,4n`, hacia arriba porque `salary` se interpreta como el número 0), `uniq -c` (cuenta un registro fantasma), `wc -l` (desviado en uno) y `join` (el encabezado es una clave sin emparejar). La corrección estándar es `tail -n +2 file`, que empieza la salida en la línea 2. Un idiomático más corto para el mismo trabajo es `sed 1d file`.

**A0.2** — `wc -l` cuenta caracteres de nueva línea, así que un archivo cuya última línea carece de salto de línea final informa uno menos que el recuento visible de líneas. Demuéstrelo con `tail -c 1 file | od -c`: si el último byte no es `\n`, la salida muestra el carácter en lugar de `\n`. `cat -A file | tail -n 1` es igual de concluyente: una línea final sin `$` al final está sin terminar.

### Bloque 1

**A1.1** — Tres líneas × (5, 4 o 5 bytes de contenido + `\r` + `\n`): `alpha`(5)+2 = 7, `beta`(4)+2 = 6, `gamma`(5)+2 = 7 → 20 bytes. `wc -l` cuenta solo los tres bytes `\n`; los tres bytes `\r` son datos ordinarios que inflan `-c` sin afectar a `-l`.

**A1.2** — Envíe `0d`. `\r` es la *representación* que hace `od` del byte 0x0D, y la misma secuencia de dos caracteres `\` `r` también podría ser una barra invertida literal seguida de `r` en los datos de origen — `od -c` imprime una barra invertida literal como `\\`, pero quien lee suele pasarlo por alto. La forma hexadecimal es inequívoca por construcción: un byte, un valor de dos dígitos. `od -A d -t x1z` es lo mejor de ambos: bytes en hexadecimal más una columna lateral ASCII para orientarse.

**A1.3** — El locale, en concreto `LC_ALL`/`LC_CTYPE`/`LANG`. Bajo un `LC_CTYPE` UTF-8, `wc -m` decodifica las secuencias multibyte y cuenta `ñ` como un carácter → 4. Bajo `LC_ALL=C` el juego de caracteres es de un solo byte, así que cada byte es un carácter y `wc -m` iguala a `wc -c` → 5.

**A1.4** — `cat -n`. Numera todas las líneas incondicionalmente, no usa ceros a la izquierda y está presente en BusyBox, mientras que `nl` en BusyBox o falta o es un esbozo. Lo que pierde es el control de formato de `nl`: sin ancho `-w`, sin separador `-s`, sin `-n rz`/`ln`, sin estilo de cuerpo `-b`, sin secciones lógicas de página (`\:\:\:`) para numeración de encabezado/cuerpo/pie.

**A1.5** — Cualquiera de estos: un proceso extra más un pipe extra significan una copia completa adicional de los 4 GB a través de los búferes de pipe del kernel (dos cambios de contexto por cada 64 KB en lugar de uno); `grep` pierde la capacidad de hacer `mmap`/seek sobre el archivo regular y de informar el nombre del archivo; y se desactivan las optimizaciones propias de `grep` que dependen de conocer el tamaño de la entrada. La medible es el rendimiento: la copia a través del pipe es CPU real y ancho de banda de memoria real.

### Bloque 2

**A2.1** — Para un archivo de 10 líneas, `tail -n 3` imprime las líneas 8, 9 y 10 (las últimas tres). `tail -n +3` imprime las líneas 3 a 10 (empezando **en** la línea 3, ocho líneas).

**A2.2** — Sobre un archivo regular, `tail` puede hacer `lseek` hasta cerca del final y leer hacia atrás hasta encontrar N saltos de línea, tocando solo la cola del archivo — memoria O(N), E/S O(N) independientemente del tamaño del archivo. Sobre un pipe no hay seek, así que `tail` debe leer el flujo entero y mantener en memoria un búfer rotatorio con las últimas N líneas — E/S O(entrada total) y memoria O(N líneas × longitud de línea). `tail -n 5` sobre un pipe es barato; `tail -n 5000000` sobre un pipe puede provocar un OOM.

**A2.3** — Use `-F`. Con `-f`, `tail` mantiene abierto el descriptor de archivo, que sigue al *inodo*; tras `mv app.log app.log.1`, ese inodo es ahora el archivo rotado, así que estará observando en silencio un archivo en el que ya nada escribe. `-F` (= `--follow=name --retry`) reabre por ruta, detecta el reemplazo e informa `has become inaccessible` / `has appeared; following new file`.

**A2.4** — `head -c` cuenta bytes y cortará alegremente una secuencia UTF-8 multibyte por la mitad, dejando una secuencia truncada que se representa como `�` o directamente no se ve, y eso rompe a cualquier consumidor posterior que valide UTF-8. Alternativas más seguras: `head -n N` (orientado a líneas, siempre cae en un límite) o `cut -c1-N` (orientado a caracteres bajo un locale UTF-8). Si se requiere un tope duro en bytes, trunque con `head -c` y luego repare con `iconv -c -f UTF-8 -t UTF-8`.

**A2.5** — `head -n 45 huge.file | tail -n 6`. `head` deja de leer tras 45 líneas y termina, enviando `SIGPIPE` aguas arriba, así que solo se leen del disco las primeras ~45 líneas: los 90 GB restantes nunca se tocan. El orden inverso, `tail -n +40 huge.file | head -n 6`, es correcto pero lee el archivo entero. El equivalente de un solo proceso con la misma salida temprana: `sed -n '40,45p;45q' huge.file`.

### Bloque 3

**A3.1** — `cut -d: -f3,1` imprime `username:uid`: `cut` ordena y deduplica la lista de campos y siempre emite los campos en el orden del archivo, así que la petición de reordenar se ignora. Se corrige con `paste`:

```bash
paste -d' ' <(cut -d: -f3 /etc/passwd) <(cut -d: -f1 /etc/passwd)
```

**A3.2** — `ls -l` rellena las columnas con *secuencias de longitud variable* de espacios para alinearlas, así que el N-ésimo campo delimitado por espacios no es la N-ésima columna; `access.log` usa exactamente un espacio como delimitador verdadero, así que la posición del campo y la de la columna coinciden. (Normalice primero `ls -l` con `tr -s ' '`.)

**A3.3** — `tr -d '\n'` elimina también el salto de línea final, dejando una salida sin terminador de línea, de modo que el prompt de la shell aparece en la misma línea y el resultado no es un archivo de texto válido. `paste -sd ''` une las líneas en un solo registro pero aun así termina ese registro con un salto de línea.

**A3.4** — Pueden discrepar. GNU `tr` está orientado a bytes: no decodifica caracteres multibyte, así que `[:lower:]`/`[:upper:]` se expanden a los miembros de un solo byte de esas clases en el locale actual, y `ä` (dos bytes en UTF-8: `c3 a4`) no es mapeado por ninguna de las dos formas. `tr 'a-z' 'A-Z'` además interpreta `a-z` como un rango de bytes ASCII, así que nunca toca lo no ASCII. Ninguna de las dos formas es un plegador de mayúsculas Unicode correcto; para eso use `sed 's/.*/\U&/'` *(GNU)* o una herramienta consciente del locale.

**A3.5** — `tr -d '\r' < dos.txt > unix.txt && mv unix.txt dos.txt` (`tr` no puede editar in situ porque solo lee de stdin y escribe en stdout — redirigir al mismo archivo lo truncaría antes de leerlo). `sed -i 's/\r//' dos.txt` es una trampa porque `\r` como escape de CR dentro de una expresión regular es una extensión de GNU: `sed` de POSIX/BSD interpreta `\r` como una `r` literal y borraría todas las letras `r` del archivo. La forma portable de `sed` usa un CR literal: `sed -i "s/$(printf '\r')//" dos.txt`.

### Bloque 4

**A4.1** — Con `-k4,4n`, las dos filas de 61000 tienen claves iguales. Como no se dio `-s`, GNU `sort` recurre a comparar las líneas completas — y el manual especifica que esta comparación de último recurso se comporta *«como si no se hubiera especificado ninguna opción de ordenación distinta de `--reverse`»*. Se especificó `-r`, así que el recurso queda invertido: `1006:silva…` se ordena antes que `1002:kim…`. Añadir `-s` desactiva por completo ese recurso y la estabilidad de la ordenación por mezcla preserva el orden de entrada, de modo que `kim` (2.º en el archivo) precede a `silva` (6.º).

**A4.2** — `-k2` significa «desde el inicio del campo 2 hasta el final de línea»; `-k2,2` significa «solo el campo 2». Entrada:

```
b 2 z
b 2 a
```

`sort -k2,2` ve claves iguales para ambas líneas; `sort -k2` compara `2 z` contra `2 a` y pone primero la línea de la `a`. Cualquier archivo donde el campo 2 empate pero los campos posteriores difieran las distinguirá.

**A4.3** — La imagen base cambió el locale por defecto (típicamente de `C`/`POSIX` a `C.UTF-8` o a un locale de glibc, o al revés), así que `sort` usa ahora una colación distinta y produce un orden distinto byte a byte de las mismas líneas. La corrección es un solo token: `LC_ALL=C sort data.txt > data.sorted`. Fije el locale en todo pipeline sometido a sumas de verificación.

**A4.4** — `sort -n` analiza un número inicial y se detiene en el primer byte no numérico, así que `1K`, `1M` y `1G` comparan todos como el número 1; el orden entre ellos recae entonces en la comparación de línea completa de último recurso, dando `1G 1K 1M`. El flag correcto es `-h` (`--human-numeric-sort`), que entiende los sufijos SI/IEC K, M, G, T, P, E, Z, Y. Existe precisamente para que `du -h | sort -h` funcione.

**A4.5** — `-T DIR` (`--temporary-directory`) para volcar a un lugar con espacio, y `--compress-program=gzip` (o `zstd`) para comprimir los tramos temporales. `-S SIZE` (`--buffer-size`), aumentando el búfer en memoria, reduce la cantidad de tramos volcados y es la tercera palanca. `--parallel=N` afecta a la velocidad, no al espacio.

**A4.6** — `sort -u` aplica la unicidad a la **clave**, no a la línea completa. `sort -k3,3 -u` conserva una línea por cada campo 3 distinto y descarta el resto, lo cual es un agrupamiento (group-by), no una deduplicación. `sort | uniq` siempre compara la línea completa. Solo coinciden cuando no se da ningún `-k`. (El capstone 2 depende exactamente de esta diferencia.)

### Bloque 5

**A5.1** — `10:13:01`, la primera de las tres. `uniq` siempre emite la **primera** línea de cada secuencia de líneas iguales adyacentes; las líneas suprimidas simplemente se descartan, así que cualquier campo excluido de la comparación muestra el valor del primer registro. Si necesita la última, invierta el flujo antes con `tac`.

**A5.2** — `uniq` solo colapsa líneas iguales *adyacentes*, así que a menos que la entrada ya esté agrupada, los registros idénticos dispersos por el archivo se cuentan por separado (el paso 1 lo demuestra). Omisión deliberada: cuando la entrada es un flujo **ordenado o naturalmente agrupado** — un log ordenado, registros en orden temporal salidos de `zcat`, o la salida de un `sort` previo — volver a ordenar es trabajo desperdiciado; y cuando el flujo es ilimitado (`tail -f`), `sort` no puede usarse en absoluto porque necesita ver EOF, así que `uniq` a solas sobre duplicados adyacentes es la única opción.

**A5.3** — `uniq -f` está cableado a campos delimitados por espacios en blanco, sin equivalente de `-t`. Traduzca el delimitador a un espacio, ejecute `uniq` y traduzca de vuelta: `tr ':' ' ' < file | uniq -f 2 | tr ' ' ':'`. Esto es seguro solo cuando los datos no contienen espacios; si no, extraiga previamente la clave de comparación con `cut` y vuelva a unir con `paste`.

**A5.4** — `sort -u` descarta los duplicados durante la ordenación, así que para cuando `uniq -c` se ejecuta hay exactamente una copia de cada línea y todos los contadores son 1:

```bash
cut -d' ' -f6 access.log | sort -u | uniq -c
```
```
      1 10.0.0.4
      1 10.0.0.7
      1 10.0.0.9
```

Contar exige que los duplicados sobrevivan hasta `uniq`; la deduplicación debe ser trabajo de `uniq`, no de `sort`.

**A5.5** — `sort` debe almacenar en búfer la entrada completa (volcando a `$TMPDIR`) antes de poder emitir su primera línea, así que necesita ~400 GB de espacio de trabajo y añade latencia ilimitada: fatal para un pipeline de streaming. `uniq` a solas solo se vuelve viable si se garantiza que los duplicados son **adyacentes** en el flujo — por ejemplo, si el productor emite registros agrupados por clave, o si los duplicados son retransmisiones que llegan seguidas dentro de una ventana acotada. En caso contrario, la arquitectura correcta es un filtro probabilístico de memoria acotada o un almacén con clave, no un pipeline de coreutils.

### Bloque 6

**A6.1** — Dirija la sustitución a las líneas que no empiezan por `#`:

```bash
sed '/^#/! s/8080/80/' config.conf
```

El `!` niega la dirección precedente, así que `s` se ejecuta solo en las líneas que no son comentarios. (Note que el espacio tras `!` es opcional en GNU sed pero obligatorio en algunas implementaciones.)

**A6.2** — Para el archivo de ejemplo son idénticos: `d` elimina las líneas coincidentes del flujo de salida por defecto, `-n` más `!p` imprime solo las no coincidentes. Difieren cuando el script tiene otros comandos de salida o cuando la última línea de la entrada está sin terminar — y, críticamente, `-n '/^#/!p'` no emitirá nada en absoluto si olvida que `-n` es obligatorio, mientras que `d` funciona con la salida por defecto. También difieren bajo `-i` combinado con comandos de impresión adicionales, donde `-n` suprime la copia implícita de cada línea. En la práctica: use `d` para «eliminar estas» y `-n …p` para «conservar solo estas».

**A6.3** — Sin `q`, `sed` lee y evalúa los 60 M de líneas aunque los últimos 55 M no producen salida: no tiene forma de saber que la dirección no volverá a coincidir. Con `{p;q}` termina inmediatamente tras la línea 5 000 000, leyendo ~8 % del archivo. En un log de 60 M de líneas y varios GB, la diferencia es aproximadamente 12× menos E/S y CPU — típicamente minutos frente a segundos. `q` además propaga `SIGPIPE` aguas arriba, así que un `zcat` que lo alimente también deja de descomprimir.

**A6.4** — `sed -i` no edita el archivo in situ. Escribe el resultado en un archivo temporal del mismo directorio y luego hace `rename(2)` sobre el destino. El renombrado asigna un **inodo nuevo**, así que cualquier cosa que retenga el inodo antiguo (un proceso en ejecución con el archivo abierto, un bind mount del *archivo* en lugar de su directorio, un enlace duro) sigue viendo el contenido antiguo — y sobre un archivo individual montado con bind el kernel rechaza el renombrado con `EBUSY`. La solución es escribir a través del inodo existente: `sed 's/…/…/' f > /tmp/f && cat /tmp/f > f`.

**A6.5** —

```bash
sed 's/\/etc\/nginx\/conf\.d/\/opt\/nginx\/conf.d/'
sed 's|/etc/nginx/conf\.d|/opt/nginx/conf.d|'
```

Ponga el segundo en el playbook. La forma escapada es ilegible y cada barra escapada es un lugar donde introducir una errata que cambia el patrón en silencio; el delimitador alternativo elimina esa clase de error por completo. Note que `.` sigue necesitando escaparse en el *patrón* (no en el reemplazo) en ambas formas.

### Bloque 7

**A7.1** — `join` informa el desorden por stderr pero, en el comportamiento histórico por defecto, aun así termina con estado 0 en la ejecución, así que `set -e` no se dispara y el script continúa con un conjunto de resultados silenciosamente truncado, lo que es peor que un fallo: los datos parecen plausibles. `--check-order` convierte una entrada desordenada en un error fatal con salida distinta de cero. (`--nocheck-order` es lo contrario y nunca debería aparecer en producción.) El patrón robusto es ordenar usted mismo ambas entradas dentro de sustituciones de proceso.

**A7.2** — (1) Colaciones distintas entre las dos ordenaciones: un archivo ordenado bajo `en_US.UTF-8` y el otro bajo `C`, o uno ordenado antes de un cambio de locale; la colación de glibc ignora la puntuación y las mayúsculas de maneras que la comparación byte a byte de `join` no. (2) Espacios en blanco finales o un CR de un archivo CRLF pegados a la clave de unión, de modo que `dev` y `dev\r` nunca coinciden. Ambos se diagnostican con `join -t: --check-order` más `cat -A` sobre la columna de la clave.

**A7.3** — `0` = el propio campo de unión; `1.2` = campo 2 del primer archivo; `2.2` = campo 2 del segundo archivo. Sin `-o`, `-e` sigue aplicándose pero solo a los campos que `-a` dejó sin emparejar — y con el formato de salida por defecto esos campos simplemente están ausentes en lugar de rellenados, así que `-e` es efectivamente inerte salvo que `-o` los nombre explícitamente. Por eso `-a` y `-e` casi siempre se escriben junto con `-o`.

**A7.4** —

```bash
join -t: -v 1 dept-owner.txt dept-budget.txt
```

Para este conjunto de datos el resultado está vacío (todos los departamentos con responsable tienen presupuesto). Añadir una fila como `sre:patel` a `dept-owner.txt`, reordenar y volver a ejecutarlo produce `sre:patel`.

**A7.5** — `join` es una **fusión por ordenación y mezcla** (sort-merge join). Su precondición es que ambas entradas estén ordenadas por la clave de unión bajo la misma colación; dado eso, avanza dos cursores al unísono y solo mantiene en memoria el grupo de la clave actual, así que el pico de memoria es proporcional al grupo más grande, no al tamaño del archivo. Una fusión por hash debe construir en memoria una tabla hash de una de las entradas completa antes de sondear, así que su memoria es proporcional a esa entrada — por lo cual `join` maneja entradas mayores que la RAM y una búsqueda ingenua no.

### Bloque 8

**A8.1** — `wc -w` cuenta tokens delimitados por espacios en blanco. Cada línea de `employees.txt` es una única cadena delimitada por dos puntos sin espacios ni tabuladores, así que cada línea es exactamente una palabra → 10 palabras para 10 líneas. `access.log` tiene 6 tokens separados por espacios por línea × 10 líneas = **60 palabras**.

**A8.2** — `-n l/3` es lo correcto para un log. `-n 3` a secas divide el archivo en tres rangos de **bytes** iguales y corta donde caiga el límite de bytes, así que una línea queda partida entre dos fragmentos; cada fragmento contiene entonces un registro truncado en su cabeza o su cola, lo que rompe cualquier análisis por fragmento y corrompe los recuentos en silencio. `-n l/3` desplaza cada límite hacia adelante hasta el siguiente salto de línea, así que los fragmentos son desiguales en bytes pero todos contienen líneas completas. (Concatenar de nuevo los fragmentos por bytes sigue reproduciendo el original exactamente: la corrupción es solo por fragmento.)

**A8.3** — GNU `split` extiende automáticamente la longitud del sufijo cuando agota el ancho actual: con `-d` y el `-a 2` por defecto usa `00`–`89` y luego pasa a `9000`–`9899`, y así sucesivamente. `cat x*` ordena entonces `x9000` antes que `x90` lexicográficamente, así que los fragmentos se concatenan fuera de orden. Corríjalo fijando el ancho de antemano —`split -d -a 4`— o usando `cat $(ls -v x*)`. La misma extensión automática existe con sufijos alfabéticos (`…yz`, `zaaa`).

**A8.4** — Integridad frente a un adversario. MD5 tiene ataques de colisión prácticos: un atacante puede construir dos archivos distintos con el mismo resumen MD5, así que un manifiesto MD5 no puede probar que un artefacto descargado es el que el publicador firmó. Para detectar corrupción accidental (bit rot, transferencia truncada) MD5 sigue siendo adecuado y más rápido. Allí donde el modelo de amenaza incluya una parte maliciosa —verificación de paquetes, artefactos de release, cadena de suministro— use `sha256sum` o `sha512sum`.

**A8.5** — `--status` no imprime absolutamente nada y se comunica solo mediante el estado de salida, que es exactamente lo que consume un condicional; sin él, `sha256sum -c` escribe `file: OK` o `file: FAILED` en stdout, contaminando la salida propia del script e intercalándose con los logs. De forma interactiva usted quiere ese informe por archivo, además de la línea de resumen que indica cuántas sumas no coincidieron. `--quiet` es el término medio: silencioso en el éxito, ruidoso en el fallo.

**A8.6** — Locales distintos en el momento de ordenar. `sort` bajo `en_US.UTF-8` y bajo `C` producen órdenes de bytes distintos de las mismas líneas, y por tanto resúmenes distintos. La corrección es fijar la colación en el pipeline: `LC_ALL=C sort file | sha256sum`. Causas de segundo orden a descartar: finales de línea CRLF frente a LF, y una diferencia de salto de línea final introducida por un editor.

### Bloque 9

**A9.1** — (1) `zcat` transmite en flujo: descomprime incrementalmente y escribe en stdout, así que `head` obtiene sus 5 líneas de los primeros pocos KB de datos comprimidos. `gunzip huge.gz` debe descomprimir los 40 GB completos *y* escribirlos en disco antes de que `head` siquiera empiece. (2) Cuando `head` termina cierra el extremo de lectura del pipe; el siguiente `write(2)` de `zcat` provoca `SIGPIPE` y el proceso muere, de modo que la descompresión *se detiene* en lugar de solo ser ignorada. `gunzip` a un archivo requiere además ~40 GB de espacio libre que `zcat` nunca toca.

**A9.2** — DEFLATE es un flujo con estado: la ventana deslizante LZ77 implica que la decodificación del byte N depende de los 32 KB previos de salida ya descomprimida, y los códigos Huffman están alineados a bit sin puntos de reinicio direccionables por byte. No existe un índice de desplazamiento de salida a desplazamiento comprimido. La línea 5 cae dentro del primer bloque, así que bastan unos pocos KB; la línea 5 000 000 exige descomprimir todo lo anterior. Los formatos que soportan acceso aleatorio añaden límites de bloque explícitos más un índice: `bgzip`/BGZF, `zstd --long` con tabla de búsqueda, o `xz` con `--block-size`.

**A9.3** — `bzcat` no forma parte de GNU coreutils; viene con `bzip2` (igual que `bzip2recover`, `bzless`, `bzgrep`). Del mismo modo, `xzcat` viene de XZ Utils y `zcat` de GNU gzip. Solo `cat`, `cut`, `sort`, `uniq`, `head`, `tail`, `wc`, `split`, `join`, `paste`, `tr`, `nl`, `od`, `pr`, `md5sum`, `sha*sum` y `expand`/`unexpand`/`fmt` son coreutils. En un contenedor mínimo (`distroless`, `alpine` con BusyBox, `scratch` + coreutils) cualquiera de los tres descompresores puede faltar, así que un script de envío debe sondear con `command -v bzcat` y fallar con un mensaje claro en lugar de con un `command not found` en medio de un pipeline.

**A9.4** —

```bash
zcat -f app.log app.log.1 app.log.2.gz | wc -l
```

`-f` (`--force`) hace que `zcat` copie sin cambios las entradas que no son gzip en lugar de dar error, así que las entradas comprimidas y planas mezcladas funcionan en una sola invocación y una sola pasada.

**A9.5** — `.Z` es la salida de la histórica utilidad `compress(1)`, que usa LZW en lugar de DEFLATE. `zcat` de GNU es `gzip -cd` y gzip conserva soporte de descompresión LZW, así que lee `.Z`, `.z` y `.gz` por igual. Los sistemas donde falla ejecutan el `zcat` de BusyBox o una compilación sin soporte LZW, o tienen `zcat` enlazado simbólicamente a `zstdcat`. La lección: `zcat` no es una única especificación — compruebe qué informa `zcat --version` antes de confiar en su cobertura de formatos de entrada.

### Bloque 10

**A10.1** — 141 = 128 + 13; una shell informa un hijo terminado por señal como 128 + número de señal, y la señal 13 es `SIGPIPE`. Así que `seq` fue terminado por `SIGPIPE` cuando `head` cerró el pipe, y `head` salió con 0. El pipeline **tuvo éxito**: el 141 es la consecuencia esperada y sana de la salida temprana de `head`, no un error. `$?` a solas habría informado 0 (el estado del último comando); solo `PIPESTATUS` expone el 141.

**A10.2** — Bajo `pipefail`, el estado del pipeline es el estado distinto de cero más a la derecha, así que la muerte por `SIGPIPE` de `zcat` (141) se convierte en el estado del pipeline y `set -e` aborta el paso. Es intermitente porque en archivos pequeños `zcat` a veces termina de escribir antes de que `head` cierre el pipe, saliendo con 0. Dos correcciones: (a) desactive la opción alrededor de ese comando — `set +o pipefail; zcat huge.gz | head -n 100 > sample.txt; set -o pipefail`; (b) elimine el cierre temprano haciendo que un único proceso realice el truncado — `zcat huge.gz | sed -n '1,100p;100q' > sample.txt` sigue teniendo el mismo problema, así que la forma robusta es `zcat huge.gz 2>/dev/null | { head -n 100 > sample.txt; cat > /dev/null; }`, o simplemente tolerar el estado explícitamente: `... || [ "${PIPESTATUS[0]}" -eq 141 ]`.

**A10.3** — Almacenamiento en búfer completo de stdio. Cuando la stdout de `cut` es un pipe en lugar de un TTY, libc cambia del búfer por líneas al búfer por bloques con un búfer por defecto de 4096 bytes, así que nada se vacía hasta acumular 4 KB — de ahí el silencio y luego la ráfaga. Corríjalo con `stdbuf -oL cut -d' ' -f5` (o `stdbuf -o0` para sin búfer). Herramientas con su propio flag: `sed -u`, `grep --line-buffered`, `awk` con `fflush()`. Note que `stdbuf` no puede afectar a un programa que fija su propio búfer, razón por la cual no funciona con `tee` ni con binarios enlazados estáticamente.

**A10.4** — Cualquier línea donde una secuencia de espacios no empiece en una posición de tabulación, o donde los espacios sean semánticamente significativos. Ejemplo: `printf 'ab  cd\n'` con `-t 4`. `unexpand -a -t 4` convierte los dos espacios de las columnas 2–3 en un tabulador que llega a la columna 4, y `expand -t 4` convierte ese tabulador de vuelta en dos espacios — este caso sí hace el viaje de ida y vuelta. Pero `printf 'a b\n'` no lo toca `unexpand -a` (un espacio suelto nunca se convierte), mientras que `printf 'x\t y\n' | expand -t 4 | unexpand -a -t 4` colapsa la secuencia de tabulador más espacio de forma distinta al original. El enunciado general: `expand` es inyectiva pero `unexpand -a` no lo es — mapea muchos patrones de espacios distintos al mismo patrón de tabuladores, así que la composición es con pérdida para cualquier espacio en blanco que no se alinee exactamente con las posiciones de tabulación.

**A10.5** — `/pattern` busca y salta a la siguiente coincidencia, dejando en pantalla todas las líneas no coincidentes de alrededor; `&pattern` **filtra** la visualización para mostrar solo las líneas coincidentes, como un `grep` interactivo que puede desactivar con un `&` a secas. En un log de 2 GB esto importa porque puede acotar iterativamente (`&error`, y luego `/timeout` dentro de la vista filtrada) sin salir del paginador, sin releer el archivo y sin perder su posición — mientras que canalizar a `grep` significa releer 2 GB por cada refinamiento.

**A10.6** — `more` lee y almacena en búfer solo hacia adelante; sobre un archivo al que se le está añadiendo contenido no puede incorporar fácilmente lo nuevo ni desplazarse hacia atrás más allá de lo ya mostrado. `less` lee de forma perezosa, mantiene el archivo entero direccionable y admite movimiento hacia atrás, búsqueda en ambas direcciones y el modo seguimiento `F`. `less +F` supera a `tail -f` porque un único `Ctrl-C` lo saca del modo seguimiento a un paginador completo situado en el punto de interés, donde puede desplazarse hacia atrás, buscar y luego pulsar `F` para reanudar el seguimiento — con `tail -f`, el desplazamiento hacia atrás es el de la terminal, está acotado y no es buscable.

### Capstone

**AC.1** — La propiedad que lo sostiene es que la ordenación por mezcla de GNU `sort` es **estable cuando `-u` está en efecto**: con `-u`, la comparación devuelve en cuanto las claves quedan decididas, se omite el recurso final de comparación de línea completa y, por tanto, las líneas con clave igual conservan el orden de entrada — de modo que la primera línea de cada grupo `dept` en el orden entrante (salario descendente) es la que se conserva. Qué lo rompería: añadir `-r` a la segunda ordenación (invierte el orden del grupo), reemplazar `sort -u` por `sort | uniq` (compara líneas completas, así que no deduplica nada) o reordenar las dos ordenaciones (el orden por salario debe existir *antes* de que la deduplicación lo consuma). Añadir `-k4,4` a la segunda ordenación también lo rompería, al cambiar la clave de unicidad.

**AC.2** — Primera ordenación, `-k3,3 -k4,4nr`: ambas filas `ops` empatan en departamento y en salario (52000). El modificador `r` está adjunto solo a la clave 4, así que el flag de inversión **global** no está activado. Por lo tanto, la comparación de línea completa de último recurso se ejecuta hacia adelante, y `1007:mora:…` < `1008:haddad:…` byte a byte, así que `mora` se emite primero. La segunda ordenación, `-k3,3 -u`, conserva la primera línea `ops` que ve, que es `mora`. Si la primera ordenación se hubiera escrito `sort -t: -k3,3 -k4,4n -r`, el `-r` global invertiría el recurso final y ganaría `haddad`.

**AC.3** — Elimine el relleno de siete columnas de `uniq -c` con `tr`:

```bash
tail -n +2 employees.txt | cut -d: -f3 | sort | uniq -c | sort -rn | tr -s ' ' | cut -c2-
```

`tr -s ' '` colapsa la secuencia inicial a un solo espacio; `cut -c2-` lo descarta. Equivalente sin `cut`: canalice a través de `tr -s ' '` y acepte el único espacio inicial, o use `sort -rn | tr -s ' ' | sed 's/^ //'` si se permite `sed`.

**AC.4** — La expresión regular `\([3-9][0-9]*\|[0-9]\{2,\}\)` codifica «≥ 3» como una propiedad *léxica* de la representación decimal, así que debe enumerar cada forma de dígitos que satisface el umbral. Cambiar el umbral a 7 o a 25 implica reescribir la alternancia, y un error de uno en uno es invisible hasta que descarta silenciosamente a un atacante real. El enfoque robusto mantiene numérica la comparación numérica: ordene por contador descendente y corte la lista donde deje de importar —

```bash
zcat access.log.gz | sed -n '/ 40[13] /p' | cut -d' ' -f6 | sort | uniq -c | sort -rn
```

— y luego tome las primeras filas (`head`) o, para un umbral genuino, genere la línea límite y use `sort` para colocarla: añada un registro sintético `      3 ---THRESHOLD---` antes de `sort -rn` y `sed -n '1,/THRESHOLD/p'` para cortar ahí. El principio general: nunca recodifique aritmética como coincidencia de patrones en un pipeline de filtros.

**AC.5** — El capstone **3** es el que está en riesgo, y solo por la colación que `sort` aplica a las cadenas IPv4; con este conjunto de datos (un único resultado) la salida visible no cambia. El capstone 1 ordena numéricamente (`-rn`), lo cual es independiente del locale para dígitos ASCII. El `-k3,3` del capstone 2 compara los nombres de departamento ASCII en minúsculas `dev`/`ops`/`qa`, que colacionan igual bajo `C` y bajo `en_US.UTF-8`. El capstone 3 ordena cadenas de direcciones IP lexicográficamente; la colación de glibc ignora la puntuación en el nivel primario, así que `10.0.0.9` y `100.0.9` pueden ordenarse de forma distinta a como lo hacen bajo `C`, y cualquier campo con mayúsculas mezcladas o no ASCII divergiría directamente. El hábito correcto es fijar `LC_ALL=C` en **los tres** de todos modos: es más rápido, es determinista y hace que la salida sometida a sumas de verificación sea reproducible entre hosts, como se estableció en el Bloque 4 y en el Bloque 8.

</details>