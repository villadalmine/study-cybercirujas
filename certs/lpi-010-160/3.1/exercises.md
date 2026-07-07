# Ejercicios guiados — Tema 3.1: Archiving Files on the Command Line

**Certificación:** LPI Linux Essentials (010-160, versión 1.6) — Peso: 2
**Referencia:** [learning.lpi.org — 3.1 Archiving Files on the Command Line](https://learning.lpi.org/en/learning-materials/010-160/3/3.1/)

Trabajá en una terminal con un usuario normal (no root). Todos los ejercicios se hacen dentro de un directorio de práctica que vas a crear en el primer bloque.

---

## Bloque 1 — Preparar el entorno de práctica

1. Creá un directorio de trabajo y entrá en él:
   ```bash
   mkdir ~/practica-archivos
   cd ~/practica-archivos
   ```
2. Creá una estructura de directorios con algunos archivos de contenido variado:
   ```bash
   mkdir -p proyecto/docs proyecto/scripts
   echo "Informe anual del proyecto" > proyecto/docs/informe.txt
   echo "Notas de la reunión de julio" > proyecto/docs/notas.txt
   echo 'echo "Hola mundo"' > proyecto/scripts/saludo.sh
   ```
3. Generá un archivo grande con contenido repetitivo (ideal para ver el efecto de la compresión):
   ```bash
   yes "Linux Essentials 010-160" | head -n 100000 > proyecto/datos.txt
   ```
4. Verificá el tamaño de lo creado:
   ```bash
   du -sh proyecto
   ls -lh proyecto/datos.txt
   ```

**Preguntas de verificación:**

- **1.a** ¿Por qué un archivo con líneas repetidas como `datos.txt` es un buen candidato para demostrar compresión?
- **1.b** ¿Qué diferencia hay entre *archiving* (empaquetar) y *compression* (comprimir)? ¿Son lo mismo?

---

## Bloque 2 — Crear un archive con `tar`

1. Creá un archive **sin compresión** con todo el directorio `proyecto`:
   ```bash
   tar -cvf proyecto.tar proyecto
   ```
2. Compará el tamaño del archive con el del directorio original:
   ```bash
   ls -lh proyecto.tar
   du -sh proyecto
   ```
3. Listá el contenido del archive **sin extraerlo**:
   ```bash
   tar -tvf proyecto.tar
   ```

**Preguntas de verificación:**

- **2.a** ¿Qué significa cada una de las opciones `-c`, `-v` y `-f` en el comando del paso 1?
- **2.b** ¿Por qué `proyecto.tar` tiene un tamaño similar (o incluso levemente mayor) al del directorio original?
- **2.c** ¿Qué opción usaste para listar el contenido sin extraer, y por qué es útil hacer esto antes de extraer un archive que te pasó otra persona?
- **2.d** ¿Qué pasaría si olvidás la opción `-f`? ¿Por qué es prácticamente obligatoria en los sistemas modernos?

---

## Bloque 3 — `tar` con compresión: gzip, bzip2 y xz

1. Creá tres versiones comprimidas del mismo directorio, una con cada método:
   ```bash
   tar -czvf proyecto.tar.gz proyecto
   tar -cjvf proyecto.tar.bz2 proyecto
   tar -cJvf proyecto.tar.xz proyecto
   ```
2. Compará los tamaños resultantes junto con el `.tar` sin comprimir:
   ```bash
   ls -lh proyecto.tar proyecto.tar.gz proyecto.tar.bz2 proyecto.tar.xz
   ```
3. Listá el contenido de la versión gzip para confirmar que `tar` puede leerla directamente:
   ```bash
   tar -tzvf proyecto.tar.gz
   ```

**Preguntas de verificación:**

- **3.a** Asociá cada opción de `tar` con su método de compresión: `-z`, `-j`, `-J`.
- **3.b** Según lo que observaste en el paso 2, ordená los tres formatos de mayor a menor compresión. ¿Cuál es el *trade-off* típico de usar `xz`?
- **3.c** ¿Qué extensión de archivo corresponde convencionalmente a cada combinación? ¿La extensión es obligatoria para que `tar` funcione?

---

## Bloque 4 — Extraer archives con `tar`

1. Creá un directorio de destino y extraé el archive gzip **dentro de ese directorio** sin hacer `cd`:
   ```bash
   mkdir restaurado
   tar -xzvf proyecto.tar.gz -C restaurado
   ```
2. Verificá que la estructura se restauró completa:
   ```bash
   ls -R restaurado
   ```
3. Ahora extraé **un solo archivo** del archive, indicando su ruta interna tal como aparece al listarlo:
   ```bash
   tar -xzvf proyecto.tar.gz proyecto/docs/informe.txt
   ls -l proyecto/docs/informe.txt
   ```

**Preguntas de verificación:**

- **4.a** ¿Qué hace la opción `-C` en el paso 1? ¿Qué habría pasado sin ella?
- **4.b** ¿Por qué en el paso 3 hay que escribir la ruta completa `proyecto/docs/informe.txt` y no solo `informe.txt`?
- **4.c** ¿Cuál es la diferencia clave entre `-c`, `-x` y `-t`? ¿Pueden usarse juntas en un mismo comando?

---

## Bloque 5 — Compresión de archivos individuales: `gzip`, `bzip2`, `xz`

1. Hacé una copia de `datos.txt` para experimentar sin perder el original:
   ```bash
   cp proyecto/datos.txt datos-copia.txt
   ```
2. Comprimila con `gzip` y observá qué pasa con el archivo original:
   ```bash
   gzip datos-copia.txt
   ls -lh datos-copia.*
   ```
3. Mirá el contenido del archivo comprimido **sin descomprimirlo en disco**:
   ```bash
   zcat datos-copia.txt.gz | head -n 3
   ```
4. Descomprimilo:
   ```bash
   gunzip datos-copia.txt.gz
   ls -lh datos-copia.txt
   ```
5. Repetí el ciclo con `bzip2` y `xz` (los comandos para descomprimir son `bunzip2` y `unxz`):
   ```bash
   bzip2 datos-copia.txt && ls -lh datos-copia.txt.bz2 && bunzip2 datos-copia.txt.bz2
   xz datos-copia.txt && ls -lh datos-copia.txt.xz && unxz datos-copia.txt.xz
   ```

**Preguntas de verificación:**

- **5.a** Cuando ejecutaste `gzip datos-copia.txt`, ¿qué pasó con el archivo original? ¿En qué se diferencia este comportamiento del de `tar`?
- **5.b** `gzip`, `bzip2` y `xz` comprimen archivos individuales. ¿Qué **no** pueden hacer por sí solos, y cómo se resuelve esa limitación en la práctica?
- **5.c** ¿Qué comando usarías para ver el contenido de un `.gz` sin descomprimirlo en disco? ¿Cuáles son los equivalentes para `.bz2` y `.xz`?

---

## Bloque 6 — El formato `zip`

> Si `zip`/`unzip` no están instalados, instalálos con el gestor de paquetes de tu distribución (por ejemplo `sudo apt install zip unzip` o `sudo dnf install zip unzip`).

1. Creá un archivo zip con el directorio completo. Fijate que necesitás la opción `-r`:
   ```bash
   zip -r proyecto.zip proyecto
   ```
2. Listá el contenido sin extraer:
   ```bash
   unzip -l proyecto.zip
   ```
3. Extraelo en un directorio propio:
   ```bash
   unzip proyecto.zip -d restaurado-zip
   ls -R restaurado-zip
   ```
4. Verificá que el directorio original sigue intacto:
   ```bash
   ls proyecto
   ```

**Preguntas de verificación:**

- **6.a** ¿Para qué sirve la opción `-r` de `zip`? ¿Qué habría contenido `proyecto.zip` si la omitías?
- **6.b** ¿Qué diferencia conceptual importante hay entre `zip` y la combinación `tar` + `gzip` respecto de cuándo se comprime cada archivo?
- **6.c** ¿En qué escenario típico elegirías `zip` en lugar de `tar.gz`?
- **6.d** ¿Qué opción de `unzip` cumple un rol análogo al `-C` de `tar`?

---

## Bloque 7 — Desafío integrador

Sin mirar los bloques anteriores, resolvé este mini-escenario. Escribí cada comando antes de ejecutarlo.

1. Creá un archive comprimido con `xz` llamado `backup-docs.tar.xz` que contenga **solo** el directorio `proyecto/docs`.
2. Listá su contenido para verificar que solo incluye lo pedido.
3. Extraelo dentro de un directorio nuevo llamado `verificacion`.
4. Limpieza final: borrá todo el directorio de práctica cuando termines:
   ```bash
   cd ~ && rm -r ~/practica-archivos
   ```

**Preguntas de verificación:**

- **7.a** ¿Qué comando usaste en el paso 1?
- **7.b** En el examen te muestran el archivo `respaldo.tgz`. ¿Con qué comando único lo extraés? ¿Qué es `.tgz`?
- **7.c** Las versiones modernas de GNU `tar` pueden detectar la compresión automáticamente al extraer o listar. ¿Eso significa que `tar -xf respaldo.tar.xz` funciona sin `-J`? ¿Y al **crear** un archive?

---

<details>
<summary><strong>Respuestas</strong></summary>

### Bloque 1

- **1.a** Los algoritmos de compresión funcionan detectando y codificando redundancia. Un archivo con la misma línea repetida 100.000 veces tiene muchísima redundancia, así que se comprime a una fracción mínima de su tamaño original, lo que hace muy visible el efecto de la compresión.
- **1.b** No son lo mismo. *Archiving* es combinar varios archivos y directorios en un solo archivo (lo que hace `tar`, sin reducir el tamaño). *Compression* es reducir el tamaño de los datos (lo que hacen `gzip`, `bzip2`, `xz`). En Linux suelen combinarse: `tar` empaqueta y luego un compresor reduce el resultado (`.tar.gz`, `.tar.xz`). El formato `zip` hace ambas cosas a la vez.

### Bloque 2

- **2.a** `-c` (*create*) crea un archive nuevo; `-v` (*verbose*) muestra en pantalla cada archivo procesado; `-f` (*file*) indica que el siguiente argumento es el nombre del archivo del archive.
- **2.b** Porque `tar` solo **empaqueta**, no comprime. El archive contiene los mismos datos más metadatos propios del formato tar (cabeceras por archivo, relleno de bloques), por eso puede ser incluso un poco más grande que el contenido original.
- **2.c** La opción `-t` (*list*). Es útil para inspeccionar qué contiene un archive y qué rutas va a crear antes de extraerlo, evitando sorpresas como sobrescribir archivos existentes o desparramar cientos de archivos en el directorio actual.
- **2.d** Sin `-f`, `tar` no interpreta `proyecto.tar` como nombre de archivo y por defecto intenta usar un dispositivo de cinta (históricamente `tar` = *tape archive*), lo que en un sistema moderno produce un error. Por eso `-f nombre_archivo` va en prácticamente todos los usos actuales.

### Bloque 3

- **3.a** `-z` → gzip; `-j` → bzip2; `-J` → xz.
- **3.b** En general, de mayor a menor compresión: `xz` > `bzip2` > `gzip` (los tres muchísimo más chicos que el `.tar` plano). El *trade-off* de `xz` es que suele necesitar más tiempo de CPU y más memoria para comprimir; `gzip` es el más rápido pero comprime menos.
- **3.c** Convenciones: `.tar.gz` (o `.tgz`) para gzip, `.tar.bz2` para bzip2, `.tar.xz` para xz. La extensión es solo una convención para los humanos: `tar` funciona igual con cualquier nombre, porque el formato lo determinan las opciones (o la autodetección al leer), no la extensión.

### Bloque 4

- **4.a** `-C restaurado` le indica a `tar` que cambie al directorio `restaurado` antes de extraer. Sin ella, el contenido se habría extraído en el directorio actual, sobrescribiendo potencialmente el directorio `proyecto` existente.
- **4.b** Porque `tar` guarda cada miembro con la ruta relativa con la que fue empaquetado. Para extraer un miembro específico hay que nombrarlo exactamente como figura en la salida de `tar -t`; `informe.txt` a secas no coincide con ningún miembro del archive.
- **4.c** Son los tres modos de operación principales: `-c` crea, `-x` extrae, `-t` lista. Son mutuamente excluyentes: cada invocación de `tar` usa exactamente uno de estos modos.

### Bloque 5

- **5.a** El archivo original desapareció y fue **reemplazado** por `datos-copia.txt.gz`. Es el comportamiento por defecto de `gzip`, `bzip2` y `xz` (se puede conservar el original con la opción `-k`, *keep*). En cambio, `tar -c` crea el archive como archivo nuevo y deja los originales intactos.
- **5.b** No pueden empaquetar varios archivos o directorios en un solo archivo: operan sobre archivos individuales, uno por uno. La solución habitual es combinarlos con `tar`: primero `tar` junta todo en un archive y luego el compresor lo reduce (de ahí `.tar.gz`, `.tar.bz2`, `.tar.xz`).
- **5.c** `zcat` para `.gz`, `bzcat` para `.bz2` y `xzcat` para `.xz`. Los tres envían el contenido descomprimido a la salida estándar sin modificar el archivo en disco.

### Bloque 6

- **6.a** `-r` (*recursive*) hace que `zip` descienda por los subdirectorios e incluya todo su contenido. Sin ella, `proyecto.zip` habría contenido solo la entrada del directorio `proyecto`, sin los archivos que están adentro.
- **6.b** `zip` comprime **cada archivo individualmente** y luego los guarda en el contenedor; `tar` + `gzip` primero empaqueta todo y comprime el archive **como un todo**. Consecuencia práctica: de un zip se puede extraer un archivo suelto sin descomprimir el resto, mientras que un `.tar.gz` suele comprimir mejor (aprovecha la redundancia entre archivos), pero hay que descomprimir el flujo para llegar a los miembros.
- **6.c** Cuando el destinatario usa Windows u otro sistema donde `zip` es el formato nativo y `tar.gz` podría no abrirse fácilmente, o cuando una plataforma o servicio exige explícitamente ese formato. Es el formato de intercambio multiplataforma por excelencia.
- **6.d** `unzip archivo.zip -d directorio_destino` extrae dentro del directorio indicado, igual que `tar ... -C directorio_destino`.

### Bloque 7

- **7.a** `tar -cJvf backup-docs.tar.xz proyecto/docs` (el `-v` es opcional). Para el paso 2: `tar -tJvf backup-docs.tar.xz`; para el paso 3: `mkdir verificacion && tar -xJvf backup-docs.tar.xz -C verificacion`.
- **7.b** `tar -xzvf respaldo.tgz`. La extensión `.tgz` es simplemente la forma abreviada de `.tar.gz`: un archive tar comprimido con gzip.
- **7.c** Sí: al **extraer** (`-x`) o **listar** (`-t`), GNU `tar` moderno detecta el tipo de compresión leyendo el contenido del archivo, así que `tar -xf respaldo.tar.xz` funciona sin `-J`. Al **crear** (`-c`) la autodetección no aplica de la misma manera: hay que indicar el compresor con `-z`, `-j` o `-J` (o usar `-a`, que lo deduce de la extensión del nombre). Para el examen conviene conocer y usar las opciones explícitas.

</details>