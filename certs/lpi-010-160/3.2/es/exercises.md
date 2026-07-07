# Ejercicios guiados — Tema 3.2: Searching and Extracting Data from Files

**Certificación:** LPI Linux Essentials (010-160, versión 1.6) · **Peso:** 3

Estos ejercicios cubren redirección de I/O, *pipes*, extracción de datos con `head`, `tail`, `cut`, `sort`, `wc`, búsqueda con `grep` y expresiones regulares básicas. Realizalos en orden: cada bloque construye sobre el anterior.

> **Preparación:** trabajá en un directorio limpio para no mezclar archivos:
> ```bash
> mkdir ~/lab-3.2 && cd ~/lab-3.2
> ```

---

## Bloque 1 — Redirección de salida: `>` y `>>`

Todo proceso en Linux tiene tres canales estándar: *standard input* (stdin, descriptor 0), *standard output* (stdout, descriptor 1) y *standard error* (stderr, descriptor 2). La redirección permite enviar esos canales a archivos en lugar de la terminal.

**Pasos:**

1. Creá un archivo redirigiendo la salida de `echo`:
   ```bash
   echo "manzana" > frutas.txt
   ```
2. Mirá el contenido:
   ```bash
   cat frutas.txt
   ```
3. Ahora ejecutá esto y volvé a mirar el contenido:
   ```bash
   echo "banana" > frutas.txt
   cat frutas.txt
   ```
4. Agregá líneas **sin destruir** las existentes usando `>>`:
   ```bash
   echo "cereza" >> frutas.txt
   echo "anana" >> frutas.txt
   echo "Banana" >> frutas.txt
   cat frutas.txt
   ```

**Preguntas:**

- **1.1** Después del paso 3, ¿por qué desapareció la línea `manzana`?
- **1.2** ¿Cuál es la diferencia entre `>` y `>>`?
- **1.3** ¿Cuántas líneas debería tener `frutas.txt` al terminar el paso 4?

---

## Bloque 2 — Redirección de errores: `2>` y `/dev/null`

**Pasos:**

1. Provocá un error a propósito:
   ```bash
   ls frutas.txt no-existe.txt
   ```
   Observá que se mezclan en pantalla una línea de salida normal y una de error.
2. Redirigí **solo la salida estándar** a un archivo:
   ```bash
   ls frutas.txt no-existe.txt > salida.txt
   ```
   El error sigue apareciendo en pantalla. Verificá qué quedó guardado con `cat salida.txt`.
3. Redirigí **solo el error**:
   ```bash
   ls frutas.txt no-existe.txt 2> errores.txt
   cat errores.txt
   ```
4. Descartá los errores por completo enviándolos al "agujero negro" del sistema:
   ```bash
   ls frutas.txt no-existe.txt 2> /dev/null
   ```
5. Guardá ambos canales en archivos distintos en un solo comando:
   ```bash
   ls frutas.txt no-existe.txt > salida.txt 2> errores.txt
   ```

**Preguntas:**

- **2.1** ¿Qué número de *file descriptor* corresponde a stdout y cuál a stderr?
- **2.2** ¿Qué es `/dev/null` y para qué se usa?
- **2.3** En el paso 2, ¿por qué el mensaje de error apareció en pantalla aunque usamos `>`?

---

## Bloque 3 — Pipes: encadenar comandos con `|`

Un *pipe* (`|`) conecta el stdout de un comando con el stdin del siguiente, sin pasar por archivos intermedios.

**Pasos:**

1. Generá un archivo de trabajo con datos "tipo CSV". Copiá el bloque completo:
   ```bash
   cat > notas.csv << 'EOF'
   ana,matematica,8
   bruno,historia,6
   carla,matematica,9
   diego,fisica,7
   elena,historia,10
   fabian,matematica,4
   gina,fisica,8
   EOF
   ```
2. Contá cuántas líneas tiene el archivo:
   ```bash
   wc -l notas.csv
   ```
3. Mostrá solo las primeras 3 líneas y solo las últimas 2:
   ```bash
   head -n 3 notas.csv
   tail -n 2 notas.csv
   ```
4. Encadená comandos: mostrá **solo la cuarta línea** del archivo:
   ```bash
   head -n 4 notas.csv | tail -n 1
   ```
5. Contá cuántos archivos hay en `/etc` combinando `ls` y `wc`:
   ```bash
   ls /etc | wc -l
   ```

**Preguntas:**

- **3.1** ¿Qué diferencia conceptual hay entre `comando > archivo` y `comando1 | comando2`?
- **3.2** Explicá con tus palabras cómo funciona el paso 4 para aislar la cuarta línea.
- **3.3** ¿Qué imprime `wc` cuando se lo invoca sin opciones (sin `-l`)?

---

## Bloque 4 — Extraer columnas con `cut` y ordenar con `sort`

**Pasos:**

1. Extraé la primera columna (nombres) de `notas.csv`. La opción `-d` define el delimitador y `-f` el campo:
   ```bash
   cut -d ',' -f 1 notas.csv
   ```
2. Extraé la materia y la nota juntas:
   ```bash
   cut -d ',' -f 2,3 notas.csv
   ```
3. Ordená el archivo alfabéticamente por línea completa:
   ```bash
   sort notas.csv
   ```
4. Ahora ordenalo por la nota (tercer campo), numéricamente y de mayor a menor:
   ```bash
   sort -t ',' -k 3 -n -r notas.csv
   ```
5. Combiná todo en una tubería: listá las materias **sin repetir**:
   ```bash
   cut -d ',' -f 2 notas.csv | sort | uniq
   ```
6. Contá cuántos alumnos hay por materia:
   ```bash
   cut -d ',' -f 2 notas.csv | sort | uniq -c
   ```

**Preguntas:**

- **4.1** En `cut`, ¿qué hacen las opciones `-d` y `-f`?
- **4.2** ¿Por qué `uniq` casi siempre se usa después de `sort` y no directamente?
- **4.3** En el paso 4, ¿qué aporta cada opción: `-t ','`, `-k 3`, `-n` y `-r`?
- **4.4** Si ordenaras las notas con `sort` sin `-n` y hubiera una nota `10`, ¿dónde podría aparecer y por qué?

---

## Bloque 5 — Buscar con `grep`

**Pasos:**

1. Buscá las líneas que contienen `matematica`:
   ```bash
   grep matematica notas.csv
   ```
2. Buscá `banana` en `frutas.txt`, primero de forma normal y después ignorando mayúsculas/minúsculas:
   ```bash
   grep banana frutas.txt
   grep -i banana frutas.txt
   ```
3. Mostrá las líneas que **no** contienen `matematica`:
   ```bash
   grep -v matematica notas.csv
   ```
4. Contá cuántas líneas coinciden, sin mostrarlas:
   ```bash
   grep -c matematica notas.csv
   ```
5. Usá `grep` como filtro en una tubería: ¿qué procesos de tu usuario contienen `bash`?
   ```bash
   ps aux | grep bash
   ```

**Preguntas:**

- **5.1** ¿Qué hacen las opciones `-i`, `-v` y `-c` de `grep`?
- **5.2** ¿Cuántas líneas devolvió cada comando del paso 2 y por qué difieren?
- **5.3** En el paso 5, es común que aparezca en los resultados el propio comando `grep bash`. ¿Por qué sucede?

---

## Bloque 6 — Expresiones regulares básicas

Las *regular expressions* (regex) describen patrones de texto. Para el examen alcanza con dominar: `.` (un carácter cualquiera), `*` (cero o más repeticiones del elemento anterior), `[]` (un carácter del conjunto), `^` (inicio de línea) y `$` (fin de línea). Ojo: **no** son los *globs* del shell — en regex, `*` no significa "cualquier cosa" por sí solo.

**Pasos:**

1. Creá un archivo de prueba:
   ```bash
   cat > palabras.txt << 'EOF'
   sol
   sal
   sil
   suelo
   salero
   parasol
   EOF
   ```
2. Buscá palabras que contengan `s`, cualquier carácter, y `l`:
   ```bash
   grep 's.l' palabras.txt
   ```
3. Restringí el carácter del medio a solo vocales `a` u `o`:
   ```bash
   grep 's[ao]l' palabras.txt
   ```
4. Anclá el patrón al **inicio** de línea y luego al **fin** de línea. Comparalas:
   ```bash
   grep '^s' palabras.txt
   grep 'ol$' palabras.txt
   ```
5. Buscá líneas que empiecen con `s` y terminen con `l` (con cualquier cosa en el medio):
   ```bash
   grep '^s.*l$' palabras.txt
   ```
6. Combiná regex con archivos del sistema: listá los usuarios cuya línea en `/etc/passwd` termina en `/bin/bash`:
   ```bash
   grep 'bash$' /etc/passwd | cut -d ':' -f 1
   ```

**Preguntas:**

- **6.1** ¿Qué significa `.` en una regex y en qué se diferencia del `?` de los *globs* del shell?
- **6.2** En el paso 3, ¿qué líneas coinciden y cuáles quedan afuera respecto del paso 2?
- **6.3** ¿Qué significan `^` y `$`? En el paso 4, ¿por qué `parasol` coincide con `grep 'ol$'` pero no con `grep '^s'`?
- **6.4** ¿Qué significa exactamente el patrón `s.*l`? ¿Coincidiría con la línea `sl`?
- **6.5** ¿Por qué conviene escribir las regex entre comillas simples al usarlas con `grep`?

---

## Bloque 7 — Desafío integrador

**Pasos:**

1. Sin ejecutar nada todavía, leé este comando y predecí su salida:
   ```bash
   cut -d ',' -f 3 notas.csv | sort -n | tail -n 1
   ```
2. Ejecutalo y verificá tu predicción.
3. Construí vos un *one-liner* que responda: **¿qué alumnos sacaron 8 o más, ordenados alfabéticamente?** (Pista: `grep` con `[89]` no captura el `10`; pensá qué campo extraer primero o qué patrón anclar al final de la línea.)
4. Limpieza final:
   ```bash
   cd ~ && rm -r ~/lab-3.2
   ```

**Preguntas:**

- **7.1** ¿Qué calcula la tubería del paso 1?
- **7.2** Escribí tu solución del paso 3 y explicá cada etapa de la tubería.

---

<details>
<summary><strong>✅ Respuestas</strong></summary>

### Bloque 1
- **1.1** Porque `>` **trunca** el archivo destino antes de escribir: el contenido anterior se pierde y solo queda `banana`.
- **1.2** `>` crea el archivo (o lo vacía si existe) y escribe desde cero; `>>` crea el archivo si no existe, pero si existe **agrega** (*append*) al final sin borrar nada.
- **1.3** Cuatro líneas: `banana`, `cereza`, `anana`, `Banana`.

### Bloque 2
- **2.1** stdout es el descriptor **1**, stderr es el descriptor **2** (stdin es el 0). Por eso `2>` redirige errores; `>` es equivalente a `1>`.
- **2.2** `/dev/null` es un dispositivo especial que descarta todo lo que se escribe en él. Se usa para silenciar salidas o errores que no interesan.
- **2.3** Porque `>` redirige únicamente stdout. El mensaje de error viaja por stderr, que es un canal independiente y siguió conectado a la terminal.

### Bloque 3
- **3.1** `>` envía la salida a un **archivo** (persiste en disco); `|` envía la salida directamente al **stdin de otro proceso**, sin archivo intermedio.
- **3.2** `head -n 4` deja pasar solo las primeras 4 líneas; de ese resultado, `tail -n 1` toma la última, que es exactamente la línea 4 del archivo original.
- **3.3** Sin opciones, `wc` imprime tres valores: cantidad de **líneas**, de **palabras** y de **bytes** (más el nombre del archivo si se le pasó uno).

### Bloque 4
- **4.1** `-d` define el **delimitador** que separa los campos (acá la coma); `-f` indica qué **campo(s)** extraer, por número de posición.
- **4.2** Porque `uniq` solo elimina duplicados **adyacentes** (líneas repetidas consecutivas). Si el archivo no está ordenado, líneas iguales pero separadas no se detectan como duplicadas.
- **4.3** `-t ','` fija la coma como separador de campos; `-k 3` ordena por el tercer campo; `-n` compara numéricamente; `-r` invierte el orden (descendente).
- **4.4** Sin `-n`, `sort` compara carácter a carácter (orden lexicográfico): `10` empieza con `1`, así que quedaría antes que `4`, `6`, `7`, etc. — como si valiera "menos" que ellas.

### Bloque 5
- **5.1** `-i` ignora la distinción entre mayúsculas y minúsculas (*case-insensitive*); `-v` invierte la búsqueda (muestra las líneas que **no** coinciden); `-c` imprime solo la **cantidad** de líneas coincidentes.
- **5.2** `grep banana` devuelve 1 línea (`banana`); `grep -i banana` devuelve 2 (`banana` y `Banana`), porque con `-i` la `B` mayúscula también coincide.
- **5.3** Porque la propia línea de proceso de `grep bash` contiene la palabra `bash` en sus argumentos, y `ps` la lista mientras `grep` todavía se está ejecutando: el filtro se encuentra a sí mismo.

### Bloque 6
- **6.1** En regex, `.` representa **exactamente un carácter cualquiera** — el mismo rol que cumple `?` en los *globs* del shell. Son dos lenguajes de patrones distintos: los globs los expande el shell sobre nombres de archivo; las regex las interpreta `grep` sobre el contenido.
- **6.2** Coinciden `sol`, `sal`, `salero` y `parasol` (todas tienen `s`+`a/o`+`l`). Queda afuera `sil`, que en el paso 2 sí coincidía porque `.` aceptaba la `i`. (`suelo` no coincide en ninguno de los dos: entre la `s` y la `l` hay dos caracteres, no uno.)
- **6.3** `^` ancla el patrón al **inicio** de la línea y `$` al **final**. `parasol` termina en `ol`, así que `ol$` coincide; pero empieza con `p`, no con `s`, así que `^s` no.
- **6.4** `s.*l` = una `s`, seguida de **cero o más** caracteres cualesquiera (`.*`), seguida de una `l`. Sí coincidiría con `sl`, porque `*` admite cero repeticiones. En el paso 5 coinciden `sol`, `sal` y `sil` (empiezan con `s` y terminan con `l`).
- **6.5** Para que el shell no interprete los metacaracteres antes de que lleguen a `grep`: sin comillas, `*`, `$` o `[]` podrían expandirse como globs o variables y el patrón que recibe `grep` sería otro.

### Bloque 7
- **7.1** La **nota más alta** del archivo: extrae la columna de notas, la ordena numéricamente de menor a mayor y toma la última línea. Resultado: `10`.
- **7.2** Una solución posible:
  ```bash
  grep -E ',(8|9|10)$' notas.csv | cut -d ',' -f 1 | sort
  ```
  Etapas: `grep -E ',(8|9|10)$'` conserva las líneas cuyo último campo es 8, 9 o 10 (el ancla `$` y la coma previa evitan falsos positivos); `cut -d ',' -f 1` extrae el nombre; `sort` ordena alfabéticamente. Resultado: `ana`, `carla`, `elena`, `gina`. Variante sin `grep -E`, filtrando después de extraer campos: `sort -t ',' -k 3 -n notas.csv | tail -n 4 | cut -d ',' -f 1 | sort` (válida aquí porque sabemos que hay exactamente 4 notas ≥ 8).

</details>

---

**Fuente de referencia:** LPI Learning Materials, Topic 3.2 — *Searching and Extracting Data from Files*: https://learning.lpi.org/en/learning-materials/010-160/3/3.2/