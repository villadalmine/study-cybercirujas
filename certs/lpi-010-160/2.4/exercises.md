# Ejercicios guiados — Tema 2.4: Creating, Moving and Deleting Files

**Certificación:** LPI Linux Essentials (010-160, v1.6) · **Peso:** 2
**Fuente de referencia:** [LPI Learning Materials 2.4](https://learning.lpi.org/en/learning-materials/010-160/2/2.4/)

> **Preparación:** trabajá en tu directorio personal. Todos los ejercicios se hacen dentro de un directorio de práctica que vas a crear en el Ejercicio 1, así no tocás archivos reales de tu sistema.

---

## Ejercicio 1 — Crear directorios con `mkdir` y archivos con `touch`

1. Abrí una terminal y asegurate de estar en tu directorio personal:
   ```bash
   cd ~
   pwd
   ```
2. Creá el directorio de práctica y entrá en él:
   ```bash
   mkdir practica24
   cd practica24
   ```
3. Creá un archivo vacío:
   ```bash
   touch notas.txt
   ```
4. Creá varios archivos vacíos en un solo comando:
   ```bash
   touch informe1.txt informe2.txt informe3.txt
   ```
5. Intentá crear una estructura anidada de directorios sin la opción adecuada y observá el error:
   ```bash
   mkdir docs/2026/julio
   ```
6. Ahora repetilo con la opción `-p` (*parents*):
   ```bash
   mkdir -p docs/2026/julio
   ```
7. Verificá todo lo creado:
   ```bash
   ls
   ls -R docs
   ```

**Preguntas:**

- **1.a)** ¿Por qué falló el paso 5 y funcionó el paso 6? ¿Qué hace exactamente `-p`?
- **1.b)** Si ejecutás `touch notas.txt` de nuevo sobre un archivo que ya existe, ¿se pierde su contenido? ¿Qué cambia en el archivo?
- **1.c)** ¿Qué opción de `mkdir` te muestra un mensaje por cada directorio creado?

---

## Ejercicio 2 — Sensibilidad a mayúsculas (case sensitivity)

1. Dentro de `practica24`, creá dos archivos que solo difieren en mayúsculas:
   ```bash
   touch Readme.txt readme.txt
   ```
2. Listá el contenido:
   ```bash
   ls
   ```
3. Escribí algo en uno de ellos y verificá que el otro sigue vacío:
   ```bash
   echo "hola" > readme.txt
   ls -l Readme.txt readme.txt
   ```

**Preguntas:**

- **2.a)** ¿Cuántos archivos distintos existen después del paso 1? ¿Qué pasaría con estos mismos comandos en un sistema de archivos típico de Windows?
- **2.b)** Si un ejercicio te pide borrar `README.TXT` pero el archivo se llama `readme.txt`, ¿qué mensaje esperás recibir de `rm`?

---

## Ejercicio 3 — Copiar con `cp`

1. Poné contenido en un archivo y copialo:
   ```bash
   echo "borrador inicial" > notas.txt
   cp notas.txt notas-backup.txt
   ```
2. Copiá un archivo dentro de un directorio existente:
   ```bash
   cp notas.txt docs/2026/julio/
   ```
3. Comprobá qué pasa cuando el destino ya existe: copiá encima de `notas-backup.txt` usando el modo interactivo:
   ```bash
   cp -i informe1.txt notas-backup.txt
   ```
   Respondé `n` para no sobrescribir.
4. Intentá copiar un directorio sin opciones y observá el error:
   ```bash
   cp docs copia-docs
   ```
5. Ahora copialo de forma recursiva:
   ```bash
   cp -r docs copia-docs
   ls -R copia-docs
   ```

**Preguntas:**

- **3.a)** En el paso 2, ¿cómo se llama el archivo resultante dentro de `docs/2026/julio/`? ¿Por qué no hizo falta escribir el nombre?
- **3.b)** ¿Qué hubiera pasado en el paso 3 sin la opción `-i`? ¿Habría alguna advertencia?
- **3.c)** ¿Por qué `cp` necesita `-r` para directorios pero no para archivos?

---

## Ejercicio 4 — Mover y renombrar con `mv`

1. Renombrá un archivo (mismo directorio, nombre nuevo):
   ```bash
   mv notas-backup.txt respaldo.txt
   ```
2. Mové un archivo a otro directorio conservando el nombre:
   ```bash
   mv respaldo.txt docs/
   ```
3. Mové y renombrá en un solo paso:
   ```bash
   mv informe3.txt docs/informe-final.txt
   ```
4. Probá el modo interactivo cuando el destino existe:
   ```bash
   touch docs/informe-final.txt.old
   mv -i docs/informe-final.txt docs/informe-final.txt.old
   ```
   Respondé `n`.
5. Renombrá un directorio completo:
   ```bash
   mv copia-docs docs-copia
   ls
   ```

**Preguntas:**

- **4.a)** En Linux no existe un comando `rename` estándar para el uso básico del examen: ¿qué comando cumple la doble función de mover y renombrar?
- **4.b)** ¿Por qué `mv` no necesita una opción `-r` para mover directorios, a diferencia de `cp`?
- **4.c)** ¿Qué diferencia práctica hay entre `mv -i` y `mv` a secas cuando el archivo de destino ya existe?

---

## Ejercicio 5 — Globbing: comodines `*`, `?` y `[ ]`

1. Creá un conjunto de archivos para practicar:
   ```bash
   mkdir globs && cd globs
   touch foto1.jpg foto2.jpg foto10.jpg documento.pdf datos.csv nota_a.txt nota_b.txt
   ```
2. Listá solo los `.jpg`:
   ```bash
   ls *.jpg
   ```
3. Listá los archivos `foto` seguidos de **un solo** carácter:
   ```bash
   ls foto?.jpg
   ```
4. Listá usando un rango de caracteres:
   ```bash
   ls nota_[ab].txt
   ```
5. Combiná comodines:
   ```bash
   ls *.[cp]*
   ```
6. Volvé al directorio de práctica:
   ```bash
   cd ..
   ```

**Preguntas:**

- **5.a)** En el paso 3, ¿aparece `foto10.jpg` en el resultado? ¿Por qué?
- **5.b)** ¿Cuál es la diferencia entre `*` y `?`?
- **5.c)** ¿Qué archivos coinciden con `nota_[ab].txt`? ¿Y con `nota_[!a].txt`?
- **5.d)** ¿Quién expande los comodines: el comando (`ls`, `rm`, etc.) o la shell? ¿Por qué importa esta distinción?

---

## Ejercicio 6 — Borrar archivos y directorios con `rm` y `rmdir`

> ⚠️ **Cuidado:** `rm` no manda nada a una papelera. Lo borrado se pierde. Trabajá siempre dentro de `practica24`.

1. Borrá un archivo individual:
   ```bash
   rm informe1.txt
   ```
2. Borrá varios archivos con un glob, pero primero **verificá** qué va a coincidir:
   ```bash
   ls informe*.txt
   rm informe*.txt
   ```
3. Probá `rmdir` con un directorio que no está vacío y observá el error:
   ```bash
   rmdir docs
   ```
4. Creá un directorio vacío y borralo con `rmdir`:
   ```bash
   mkdir temporal
   rmdir temporal
   ```
5. Borrá un directorio con contenido usando `rm` recursivo e interactivo:
   ```bash
   rm -ri docs-copia
   ```
   Respondé `y` a cada pregunta.
6. Al terminar toda la práctica, limpiá todo:
   ```bash
   cd ~
   rm -r practica24
   ```

**Preguntas:**

- **6.a)** ¿Cuál es la diferencia entre `rmdir docs` y `rm -r docs`?
- **6.b)** ¿Por qué es una buena práctica correr `ls` con el mismo glob antes de `rm` con ese glob (paso 2)?
- **6.c)** ¿Qué hacen las opciones `-i` y `-f` de `rm`? ¿Cuál "gana" si escribís `rm -if`?
- **6.d)** ¿Por qué el comando `rm -rf /` es tan citado como peligroso? (No lo ejecutes.)

---

## Ejercicio 7 — Integrador

1. Recreá una mini estructura de proyecto en un solo comando:
   ```bash
   mkdir -p proyecto/{src,docs,backup}
   ```
2. Creá archivos de trabajo:
   ```bash
   cd proyecto
   touch src/main.sh src/util.sh docs/manual.txt
   ```
3. Hacé una copia de seguridad de todo `src` dentro de `backup`:
   ```bash
   cp -r src backup/
   ```
4. Renombrá el manual:
   ```bash
   mv docs/manual.txt docs/manual-v1.txt
   ```
5. Borrá todos los `.sh` de `src` verificando primero:
   ```bash
   ls src/*.sh
   rm src/*.sh
   ```
6. Comprobá que la copia en `backup/src` sigue intacta:
   ```bash
   ls -R backup
   ```

**Preguntas:**

- **7.a)** Después del paso 5, ¿existe todavía `main.sh` en algún lugar del proyecto? ¿Dónde?
- **7.b)** Escribí un único comando que borre el directorio `proyecto` completo con confirmación por cada elemento.
- **7.c)** ¿Qué comando usarías para mover `backup/src` de vuelta a la raíz del proyecto con el nombre `src`?

---

<details>
<summary><strong>📖 Respuestas</strong></summary>

### Ejercicio 1

- **1.a)** Falló porque `mkdir` solo crea el último componente de la ruta, y `docs/2026` no existía. La opción `-p` (*parents*) crea todos los directorios intermedios que falten, y además no da error si el directorio ya existe.
- **1.b)** No, el contenido no se pierde. `touch` sobre un archivo existente solo actualiza sus marcas de tiempo (fecha de acceso y modificación). Solo crea el archivo si no existe.
- **1.c)** `mkdir -v` (*verbose*) imprime un mensaje por cada directorio creado. Se puede combinar: `mkdir -pv docs/2026/julio`.

### Ejercicio 2

- **2.a)** Existen **dos** archivos distintos: los sistemas de archivos de Linux son *case sensitive*, así que `Readme.txt` y `readme.txt` son nombres diferentes. En un sistema de archivos típico de Windows (NTFS en su modo habitual, *case insensitive*), el segundo `touch` habría actuado sobre el mismo archivo y solo existiría uno.
- **2.b)** `rm: cannot remove 'README.TXT': No such file or directory` — el nombre en mayúsculas no coincide con ningún archivo existente.

### Ejercicio 3

- **3.a)** Se llama `notas.txt`. Cuando el destino de `cp` es un directorio, el archivo se copia adentro conservando su nombre original.
- **3.b)** Sin `-i`, `cp` habría sobrescrito `notas-backup.txt` **silenciosamente**, sin ninguna advertencia. Por eso `-i` (*interactive*) es recomendable cuando hay riesgo de pisar archivos.
- **3.c)** Un directorio puede contener otros archivos y subdirectorios; copiarlo implica recorrer todo su árbol. `cp` exige `-r` (o `-R`, *recursive*) como confirmación explícita de que querés copiar toda esa estructura.

### Ejercicio 4

- **4.a)** `mv`. Renombrar es, en la práctica, mover un archivo a un nombre nuevo dentro del mismo directorio.
- **4.b)** Porque `mv` normalmente no copia los datos: cambia la entrada del directorio (la referencia al contenido), sin importar si apunta a un archivo o a un árbol entero. No necesita recorrer el contenido, así que no necesita recursión.
- **4.c)** `mv` a secas sobrescribe el destino sin avisar; `mv -i` pregunta antes de sobrescribir y permite cancelar respondiendo `n`.

### Ejercicio 5

- **5.a)** No. `?` coincide con **exactamente un** carácter, y `foto10.jpg` tiene dos caracteres entre `foto` y `.jpg`. Para incluirlo serviría `foto*.jpg` o `foto??.jpg` (este último solo para los de dos caracteres).
- **5.b)** `*` coincide con cero o más caracteres cualesquiera; `?` coincide con exactamente un carácter.
- **5.c)** `nota_[ab].txt` coincide con `nota_a.txt` y `nota_b.txt` (los corchetes aceptan un carácter del conjunto). `nota_[!a].txt` niega el conjunto: coincide con `nota_b.txt` pero no con `nota_a.txt`.
- **5.d)** Los expande la **shell** (Bash) antes de ejecutar el comando: el programa recibe la lista de nombres ya expandida. Importa porque el comportamiento es idéntico para cualquier comando (`ls`, `rm`, `cp`, `mv`…), y porque un glob mal pensado en un `rm` se expande a más archivos de los que imaginabas antes de que `rm` pueda hacer nada.

### Ejercicio 6

- **6.a)** `rmdir` solo borra directorios **vacíos** (por eso falló en el paso 3); `rm -r` borra el directorio y todo su contenido recursivamente.
- **6.b)** Porque `ls` te muestra exactamente qué archivos expande el glob, sin riesgo. Es un "ensayo" seguro: si la lista es la esperada, recién entonces ejecutás el `rm`.
- **6.c)** `-i` pide confirmación por cada archivo; `-f` (*force*) borra sin preguntar y suprime errores por archivos inexistentes. Cuando se combinan, gana la **última** opción escrita: `rm -if` se comporta como `-f`, y `rm -fi` como `-i`.
- **6.d)** Porque combina `-r` (recursivo, todo el árbol) y `-f` (sin confirmación ni errores) aplicado a `/`, la raíz del sistema: intentaría borrar todo el sistema de archivos sin preguntar nada. Las versiones modernas de `rm` (GNU coreutils) lo bloquean con la protección `--preserve-root`, pero nunca hay que confiarse.

### Ejercicio 7

- **7.a)** Sí: existe en `backup/src/main.sh`. La copia del paso 3 es independiente de los originales, así que borrar `src/*.sh` no la afecta.
- **7.b)** Desde el directorio padre de `proyecto`:
  ```bash
  rm -ri proyecto
  ```
  (`-r` para recorrer todo el árbol, `-i` para confirmar elemento por elemento).
- **7.c)** Desde la raíz del proyecto (después de haber borrado o movido el `src` original, porque si no `backup/src` quedaría adentro como `src/src`):
  ```bash
  mv backup/src src
  ```

</details>

---

**Fuente consultada:** [learning.lpi.org — Lesson 2.4: Creating, Moving and Deleting Files](https://learning.lpi.org/en/learning-materials/010-160/2/2.4/)